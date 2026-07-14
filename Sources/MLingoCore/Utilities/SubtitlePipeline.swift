import Foundation

public enum SubtitlePipelineMode: Equatable, Sendable {
    case transcriptionOnly
    case translation
}

@MainActor
public final class SubtitlePipeline {
    public typealias TranscriptHandler = @Sendable (Transcript) async -> Void
    public typealias WhisperDiagnosticsHandler = @Sendable (WhisperDiagnostics) async -> Void

    private let audioEngineFactory: any AudioEngineFactoryProtocol
    private let translationEngine: TranslationEngineProtocol
    private let overlayEngine: OverlayEngineProtocol
    private let settingsStore: SettingsStoreProtocol
    private let transcriptionCoordinator: WhisperTranscriptionCoordinator

    private var task: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var activeAudioEngine: (any AudioEngineProtocol)?
    private var queue = OrderedSubtitleQueue()
    private var pendingTranslations: [TranslationRequest] = []
    private var translationHistory: [Transcript] = []
    private var lastTranslationDedupeKey: String?
    private var translationPaused = false
    private var skippedTranslationCount = 0
    private var sessionID: UUID?
    private var activeMode: SubtitlePipelineMode?
    private var overlayVisible = false

    public init(
        audioEngineFactory: any AudioEngineFactoryProtocol,
        whisperEngine: WhisperEngineProtocol,
        translationEngine: TranslationEngineProtocol,
        overlayEngine: OverlayEngineProtocol,
        settingsStore: SettingsStoreProtocol
    ) {
        self.audioEngineFactory = audioEngineFactory
        self.translationEngine = translationEngine
        self.overlayEngine = overlayEngine
        self.settingsStore = settingsStore
        transcriptionCoordinator = WhisperTranscriptionCoordinator(engine: whisperEngine)
    }

    public func start(
        mode: SubtitlePipelineMode = .translation,
        onError: @escaping @Sendable (String) -> Void,
        onWarning: @escaping @Sendable (String) -> Void = { _ in },
        onAudioDiagnostics: (@Sendable (AudioCaptureDiagnostics) async -> Void)? = nil,
        onTranscript: @escaping TranscriptHandler = { _ in },
        onWhisperDiagnostics: @escaping WhisperDiagnosticsHandler = { _ in }
    ) async {
        MLingoLogger.pipeline.info("Starting subtitle pipeline")
        await stop()

        let newSessionID = UUID()
        sessionID = newSessionID
        activeMode = mode

        do {
            let settings = try await settingsStore.load()
            try await transcriptionCoordinator.start(
                modelID: settings.whisperModel,
                language: settings.sourceLanguage,
                onTranscript: { [weak self] transcript in
                    await self?.receive(
                        transcript,
                        mode: mode,
                        settings: settings,
                        sessionID: newSessionID,
                        onTranscript: onTranscript,
                        onError: onError,
                        onWarning: onWarning
                    )
                },
                onDiagnostics: { diagnostics in
                    await onWhisperDiagnostics(diagnostics)
                },
                onError: { [weak self] message in
                    await self?.reportError(
                        message,
                        sessionID: newSessionID,
                        handler: onError
                    )
                }
            )
            guard sessionID == newSessionID else { return }

            let audioEngine = audioEngineFactory.makeAudioEngine(
                preferredBackend: settings.audioCaptureBackend
            )
            activeAudioEngine = audioEngine
            try await audioEngine.start()
            guard sessionID == newSessionID else {
                await audioEngine.stop()
                return
            }

            if mode == .translation {
                overlayEngine.show()
                overlayVisible = true
            }
            MLingoLogger.pipeline.info("Subtitle pipeline started")

            if let onAudioDiagnostics {
                diagnosticsTask = Task { [weak self, audioEngine] in
                    for await diagnostics in audioEngine.diagnostics {
                        if Task.isCancelled { return }
                        guard self?.isCurrentSession(newSessionID) == true else { return }
                        await onAudioDiagnostics(diagnostics)
                    }
                }
            }

            let coordinator = transcriptionCoordinator
            task = Task { [weak self, audioEngine] in
                for await chunk in audioEngine.chunks {
                    if Task.isCancelled { return }
                    guard self?.isCurrentSession(newSessionID) == true else { return }
                    await coordinator.ingest(chunk)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard sessionID == newSessionID else { return }
            MLingoLogger.pipeline.error(
                "Subtitle pipeline failed to start: \(error.localizedDescription, privacy: .public)"
            )
            onError(error.localizedDescription)
            await stop()
        }
    }

    public func stop() async {
        MLingoLogger.pipeline.info("Stopping subtitle pipeline")
        sessionID = nil
        activeMode = nil
        task?.cancel()
        task = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        translationTask?.cancel()
        translationTask = nil
        let audioEngine = activeAudioEngine
        activeAudioEngine = nil
        await transcriptionCoordinator.stop()
        await audioEngine?.stop()
        queue = OrderedSubtitleQueue()
        pendingTranslations.removeAll(keepingCapacity: false)
        translationHistory.removeAll(keepingCapacity: false)
        lastTranslationDedupeKey = nil
        translationPaused = false
        skippedTranslationCount = 0
        if overlayVisible {
            overlayEngine.hide()
            overlayVisible = false
        }
        MLingoLogger.pipeline.info("Subtitle pipeline stopped")
    }

    private func receive(
        _ transcript: Transcript,
        mode: SubtitlePipelineMode,
        settings: AppSettings,
        sessionID expectedSessionID: UUID,
        onTranscript: TranscriptHandler,
        onError: @escaping @Sendable (String) -> Void,
        onWarning: @escaping @Sendable (String) -> Void
    ) async {
        guard sessionID == expectedSessionID else { return }
        await onTranscript(transcript)
        guard mode == .translation, !translationPaused else { return }

        enqueueTranslation(
            transcript,
            settings: settings,
            sessionID: expectedSessionID,
            onError: onError,
            onWarning: onWarning
        )
    }

    private func enqueueTranslation(
        _ transcript: Transcript,
        settings: AppSettings,
        sessionID expectedSessionID: UUID,
        onError: @escaping @Sendable (String) -> Void,
        onWarning: @escaping @Sendable (String) -> Void
    ) {
        guard sessionID == expectedSessionID, !translationPaused else { return }
        let dedupeKey = transcript.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !dedupeKey.isEmpty, dedupeKey != lastTranslationDedupeKey else { return }
        lastTranslationDedupeKey = dedupeKey

        let request = TranslationRequest(
            current: transcript,
            context: Array(translationHistory.suffix(2))
        )
        translationHistory.append(transcript)
        if translationHistory.count > 2 {
            translationHistory.removeFirst(translationHistory.count - 2)
        }

        if pendingTranslations.count >= 8 {
            pendingTranslations.removeFirst()
            skippedTranslationCount += 1
            onWarning(
                "Translation is falling behind. Skipped \(skippedTranslationCount) older subtitles."
            )
        }
        pendingTranslations.append(request)

        guard translationTask == nil else { return }
        translationTask = Task { [weak self] in
            await self?.drainTranslations(
                settings: settings,
                sessionID: expectedSessionID,
                onError: onError
            )
        }
    }

    private func drainTranslations(
        settings: AppSettings,
        sessionID expectedSessionID: UUID,
        onError: @escaping @Sendable (String) -> Void
    ) async {
        defer {
            if sessionID == expectedSessionID {
                translationTask = nil
            }
        }

        while sessionID == expectedSessionID,
              !translationPaused,
              !Task.isCancelled,
              !pendingTranslations.isEmpty
        {
            let request = pendingTranslations.removeFirst()

            do {
                let subtitle = try await translationEngine.translate(request, settings: settings)
                guard sessionID == expectedSessionID, !Task.isCancelled else { return }
                let ready = queue.insert(subtitle)
                for item in ready {
                    overlayEngine.update(with: item, settings: settings)
                }
            } catch is CancellationError {
                return
            } catch {
                guard sessionID == expectedSessionID, !Task.isCancelled else { return }
                onError(error.localizedDescription)

                if let mlingoError = error as? MLingoError,
                   mlingoError.pausesTranslationSession
                {
                    translationPaused = true
                    pendingTranslations.removeAll(keepingCapacity: false)
                    return
                }
            }
        }
    }

    private func reportError(
        _ message: String,
        sessionID expectedSessionID: UUID,
        handler: @escaping @Sendable (String) -> Void
    ) {
        guard sessionID == expectedSessionID else { return }
        handler(message)
    }

    private func isCurrentSession(_ expectedSessionID: UUID) -> Bool {
        sessionID == expectedSessionID
    }
}
