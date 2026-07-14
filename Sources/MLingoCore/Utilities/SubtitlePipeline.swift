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
    private var activeAudioEngine: (any AudioEngineProtocol)?
    private var queue = OrderedSubtitleQueue()
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
                        onError: onError
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
        let audioEngine = activeAudioEngine
        activeAudioEngine = nil
        await transcriptionCoordinator.stop()
        await audioEngine?.stop()
        queue = OrderedSubtitleQueue()
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
        onError: @escaping @Sendable (String) -> Void
    ) async {
        guard sessionID == expectedSessionID else { return }
        await onTranscript(transcript)
        guard mode == .translation else { return }

        do {
            let subtitle = try await translationEngine.translate(transcript, settings: settings)
            guard sessionID == expectedSessionID else { return }
            let ready = queue.insert(subtitle)
            for item in ready {
                overlayEngine.update(with: item, settings: settings)
            }
        } catch is CancellationError {
            return
        } catch {
            guard sessionID == expectedSessionID else { return }
            MLingoLogger.pipeline.error(
                "Subtitle pipeline iteration failed: \(error.localizedDescription, privacy: .public)"
            )
            onError(error.localizedDescription)
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
