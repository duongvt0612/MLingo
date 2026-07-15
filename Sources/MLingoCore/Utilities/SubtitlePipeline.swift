import Foundation

public enum SubtitlePipelineMode: Equatable, Sendable {
    case transcriptionOnly
    case translation
}

@MainActor
public final class SubtitlePipeline {
    public typealias ErrorHandler = @MainActor @Sendable (MLingoError) -> Void
    public typealias TranscriptHandler = @Sendable (Transcript) async -> Void
    public typealias WhisperDiagnosticsHandler = @Sendable (WhisperDiagnostics) async -> Void
    public typealias PerformanceDiagnosticsHandler = @Sendable (
        PipelinePerformanceDiagnostics
    ) async -> Void

    private let audioEngineFactory: any AudioEngineFactoryProtocol
    private let translationEngine: TranslationEngineProtocol
    private let overlayEngine: OverlayEngineProtocol
    private let settingsStore: SettingsStoreProtocol
    private let transcriptionCoordinator: WhisperTranscriptionCoordinator
    private let processMetricsSampler: any ProcessMetricsSampling
    private let now: PerformanceNow

    private var task: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var performanceTask: Task<Void, Never>?
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
    private var performanceTracker: PipelinePerformanceTracker?
    private var performanceHandler: PerformanceDiagnosticsHandler?
    private var subtitleTraceIDs: [UUID: UUID] = [:]

    public var overlayPresentationState: OverlayPresentationState {
        overlayEngine.presentationState
    }

    public convenience init(
        audioEngineFactory: any AudioEngineFactoryProtocol,
        whisperEngine: WhisperEngineProtocol,
        translationEngine: TranslationEngineProtocol,
        overlayEngine: OverlayEngineProtocol,
        settingsStore: SettingsStoreProtocol
    ) {
        self.init(
            audioEngineFactory: audioEngineFactory,
            whisperEngine: whisperEngine,
            translationEngine: translationEngine,
            overlayEngine: overlayEngine,
            settingsStore: settingsStore,
            processMetricsSampler: DarwinProcessMetricsSampler(),
            now: { .now }
        )
    }

    init(
        audioEngineFactory: any AudioEngineFactoryProtocol,
        whisperEngine: WhisperEngineProtocol,
        translationEngine: TranslationEngineProtocol,
        overlayEngine: OverlayEngineProtocol,
        settingsStore: SettingsStoreProtocol,
        processMetricsSampler: any ProcessMetricsSampling,
        now: @escaping PerformanceNow
    ) {
        self.audioEngineFactory = audioEngineFactory
        self.translationEngine = translationEngine
        self.overlayEngine = overlayEngine
        self.settingsStore = settingsStore
        self.processMetricsSampler = processMetricsSampler
        self.now = now
        transcriptionCoordinator = WhisperTranscriptionCoordinator(
            engine: whisperEngine,
            configuration: AdaptiveAudioWindowConfiguration(),
            now: now
        )
    }

    @discardableResult
    public func start(
        mode: SubtitlePipelineMode = .translation,
        translationSelection: ResolvedProviderSelection? = nil,
        onError: @escaping ErrorHandler,
        onWarning: @escaping @Sendable (String) -> Void = { _ in },
        onAudioDiagnostics: (@Sendable (AudioCaptureDiagnostics) async -> Void)? = nil,
        onTranscript: @escaping TranscriptHandler = { _ in },
        onWhisperDiagnostics: @escaping WhisperDiagnosticsHandler = { _ in },
        onPerformanceDiagnostics: @escaping PerformanceDiagnosticsHandler = { _ in }
    ) async -> Bool {
        MLingoLogger.pipeline.info("Starting subtitle pipeline")
        await stop()

        let newSessionID = UUID()
        sessionID = newSessionID
        activeMode = mode
        let tracker = PipelinePerformanceTracker(now: now)
        performanceTracker = tracker
        performanceHandler = onPerformanceDiagnostics
        await onPerformanceDiagnostics(PipelinePerformanceDiagnostics())

        var startStage = StartStage.settings
        do {
            let settings = try await settingsStore.load()
            startStage = .whisper
            try await transcriptionCoordinator.start(
                modelID: settings.whisperModel,
                language: settings.sourceLanguage,
                onTranscript: { [weak self] transcript in
                    await self?.receive(
                        transcript,
                        mode: mode,
                        settings: settings,
                        translationSelection: translationSelection,
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
                        .whisperInferenceFailed(message),
                        sessionID: newSessionID,
                        handler: onError
                    )
                },
                onPerformance: { update in
                    switch update {
                    case .completed(let event):
                        await tracker.recordWhisper(event)
                    case .queue(let pendingDuration, let droppedCount):
                        await tracker.updateWhisperQueue(
                            pendingDuration: pendingDuration,
                            droppedCount: droppedCount
                        )
                    }
                }
            )
            guard sessionID == newSessionID else { return false }

            let audioEngine = audioEngineFactory.makeAudioEngine(
                preferredBackend: settings.audioCaptureBackend
            )
            activeAudioEngine = audioEngine
            startStage = .audio
            try await audioEngine.start()
            guard sessionID == newSessionID else {
                await audioEngine.stop()
                return false
            }

            if mode == .translation {
                overlayEngine.show(settings: settings)
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
            let now = self.now
            task = Task { [weak self, audioEngine] in
                for await chunk in audioEngine.chunks {
                    if Task.isCancelled { return }
                    guard self?.isCurrentSession(newSessionID) == true else { return }
                    let capturedAt = now()
                    let signpostID = PerformanceSignposts.signposter.makeSignpostID()
                    let signpostState = PerformanceSignposts.signposter.beginInterval(
                        "audio.capture",
                        id: signpostID,
                        "duration_ms=\(chunk.duration * 1_000)"
                    )
                    await coordinator.ingest(chunk, capturedAt: capturedAt)
                    PerformanceSignposts.signposter.endInterval(
                        "audio.capture",
                        signpostState,
                        "status=success"
                    )
                }
            }
            await processMetricsSampler.reset()
            startPerformancePublishing(
                tracker: tracker,
                sessionID: newSessionID,
                handler: onPerformanceDiagnostics
            )
            return true
        } catch is CancellationError {
            if sessionID == newSessionID {
                await stop()
            }
            return false
        } catch {
            guard sessionID == newSessionID else { return false }
            MLingoLogger.pipeline.error(
                "Subtitle pipeline failed to start: \(error.localizedDescription, privacy: .public)"
            )
            onError(Self.startError(error, stage: startStage))
            await stop()
            return false
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
        performanceTask?.cancel()
        let stoppedPerformanceTask = performanceTask
        performanceTask = nil
        let stoppedPerformanceTracker = performanceTracker
        let audioEngine = activeAudioEngine
        activeAudioEngine = nil
        await transcriptionCoordinator.stop()
        await audioEngine?.stop()
        await stoppedPerformanceTask?.value
        queue = OrderedSubtitleQueue()
        pendingTranslations.removeAll(keepingCapacity: false)
        translationHistory.removeAll(keepingCapacity: false)
        lastTranslationDedupeKey = nil
        translationPaused = false
        skippedTranslationCount = 0
        subtitleTraceIDs.removeAll(keepingCapacity: false)
        stoppedPerformanceTracker?.updateTranslationQueue(depth: 0)
        performanceTracker = nil
        let stoppedPerformanceHandler = performanceHandler
        performanceHandler = nil
        if overlayVisible {
            overlayEngine.hide()
            overlayVisible = false
        }
        if let stoppedPerformanceHandler {
            await stoppedPerformanceHandler(
                stoppedPerformanceTracker?.snapshot() ?? PipelinePerformanceDiagnostics()
            )
        }
        MLingoLogger.pipeline.info("Subtitle pipeline stopped")
    }

    public func setOverlayVisible(_ isVisible: Bool) {
        guard activeMode == .translation else { return }
        overlayEngine.setVisible(isVisible)
    }

    public func beginOverlayRepositioning() {
        guard activeMode == .translation else { return }
        overlayEngine.beginRepositioning()
    }

    public func endOverlayRepositioning() {
        guard activeMode == .translation else { return }
        overlayEngine.endRepositioning()
    }

    public func resetOverlayPosition() {
        guard activeMode == .translation else { return }
        overlayEngine.resetPosition()
    }

    public func selectOverlayDisplay(_ selection: OverlayDisplaySelection) {
        overlayEngine.selectDisplay(selection)
    }

    private func receive(
        _ transcript: Transcript,
        mode: SubtitlePipelineMode,
        settings: AppSettings,
        translationSelection: ResolvedProviderSelection?,
        sessionID expectedSessionID: UUID,
        onTranscript: TranscriptHandler,
        onError: @escaping ErrorHandler,
        onWarning: @escaping @Sendable (String) -> Void
    ) async {
        guard sessionID == expectedSessionID else { return }
        await onTranscript(transcript)
        guard sessionID == expectedSessionID,
              mode == .translation,
              !translationPaused
        else {
            performanceTracker?.discardTrace(transcriptID: transcript.id)
            return
        }

        enqueueTranslation(
            transcript,
            settings: settings,
            translationSelection: translationSelection,
            sessionID: expectedSessionID,
            onError: onError,
            onWarning: onWarning
        )
    }

    private func enqueueTranslation(
        _ transcript: Transcript,
        settings: AppSettings,
        translationSelection: ResolvedProviderSelection?,
        sessionID expectedSessionID: UUID,
        onError: @escaping ErrorHandler,
        onWarning: @escaping @Sendable (String) -> Void
    ) {
        guard sessionID == expectedSessionID, !translationPaused else { return }
        let dedupeKey = transcript.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !dedupeKey.isEmpty else {
            performanceTracker?.discardTrace(transcriptID: transcript.id)
            return
        }
        guard dedupeKey != lastTranslationDedupeKey else {
            performanceTracker?.discardTrace(
                transcriptID: transcript.id,
                duplicate: true
            )
            return
        }
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
            let removed = pendingTranslations.removeFirst()
            skippedTranslationCount += 1
            performanceTracker?.discardTrace(
                transcriptID: removed.current.id,
                skipped: true
            )
            onWarning(
                "Translation is falling behind. Skipped \(skippedTranslationCount) older subtitles."
            )
        }
        pendingTranslations.append(request)
        performanceTracker?.recordTranslationQueued(
            transcriptID: transcript.id,
            at: now()
        )
        performanceTracker?.updateTranslationQueue(depth: pendingTranslations.count)

        guard translationTask == nil else { return }
        translationTask = Task { [weak self] in
            await self?.drainTranslations(
                settings: settings,
                translationSelection: translationSelection,
                sessionID: expectedSessionID,
                onError: onError
            )
        }
    }

    private func drainTranslations(
        settings: AppSettings,
        translationSelection: ResolvedProviderSelection?,
        sessionID expectedSessionID: UUID,
        onError: @escaping ErrorHandler
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
            performanceTracker?.updateTranslationQueue(depth: pendingTranslations.count)
            let translationStarted = now()
            performanceTracker?.recordTranslationStarted(
                transcriptID: request.current.id,
                at: translationStarted
            )
            let performanceTraceID = performanceTracker?.traceID(
                for: request.current.id
            ) ?? request.current.id
            let signpostID = PerformanceSignposts.signposter.makeSignpostID()
            let signpostState = PerformanceSignposts.signposter.beginInterval(
                "translation.request",
                id: signpostID,
                "trace=\(performanceTraceID.uuidString, privacy: .public) queue=\(self.pendingTranslations.count)"
            )

            do {
                let subtitle = try await translationEngine.translate(
                    request,
                    settings: settings,
                    selection: translationSelection
                )
                let translationEnded = now()
                PerformanceSignposts.signposter.endInterval(
                    "translation.request",
                    signpostState,
                    "status=success"
                )
                performanceTracker?.recordTranslationFinished(
                    transcriptID: request.current.id,
                    at: translationEnded
                )
                guard sessionID == expectedSessionID, !Task.isCancelled else { return }
                subtitleTraceIDs[subtitle.id] = request.current.id
                let ready = queue.insert(subtitle)
                if ready.isEmpty {
                    subtitleTraceIDs[subtitle.id] = nil
                    performanceTracker?.discardTrace(transcriptID: request.current.id)
                }
                for item in ready {
                    let transcriptID = subtitleTraceIDs.removeValue(forKey: item.id)
                        ?? request.current.id
                    let renderStarted = now()
                    let renderTraceID = performanceTracker?.traceID(for: transcriptID)
                        ?? transcriptID
                    let renderSignpostID = PerformanceSignposts.signposter.makeSignpostID()
                    let renderSignpostState = PerformanceSignposts.signposter.beginInterval(
                        "overlay.render",
                        id: renderSignpostID,
                        "trace=\(renderTraceID.uuidString, privacy: .public)"
                    )
                    overlayEngine.update(with: item, settings: settings)
                    let renderEnded = now()
                    PerformanceSignposts.signposter.endInterval(
                        "overlay.render",
                        renderSignpostState,
                        "status=success"
                    )
                    performanceTracker?.recordOverlayRendered(
                        transcriptID: transcriptID,
                        startedAt: renderStarted,
                        endedAt: renderEnded
                    )
                }
            } catch is CancellationError {
                PerformanceSignposts.signposter.endInterval(
                    "translation.request",
                    signpostState,
                    "error=cancelled"
                )
                performanceTracker?.discardTrace(transcriptID: request.current.id)
                return
            } catch {
                PerformanceSignposts.signposter.endInterval(
                    "translation.request",
                    signpostState,
                    "error=\(self.performanceErrorCategory(error), privacy: .public)"
                )
                performanceTracker?.discardTrace(transcriptID: request.current.id)
                guard sessionID == expectedSessionID, !Task.isCancelled else { return }
                onError(
                    (error as? MLingoError)
                        ?? .translationFailed(error.localizedDescription)
                )

                if let mlingoError = error as? MLingoError,
                   mlingoError.pausesTranslationSession
                {
                    translationPaused = true
                    for pendingRequest in pendingTranslations {
                        performanceTracker?.discardTrace(
                            transcriptID: pendingRequest.current.id
                        )
                    }
                    pendingTranslations.removeAll(keepingCapacity: false)
                    performanceTracker?.updateTranslationQueue(depth: 0)
                    return
                }
            }
        }
    }

    private func reportError(
        _ error: MLingoError,
        sessionID expectedSessionID: UUID,
        handler: @escaping ErrorHandler
    ) {
        guard sessionID == expectedSessionID else { return }
        handler(error)
    }

    private static func startError(_ error: any Error, stage: StartStage) -> MLingoError {
        if let error = error as? MLingoError { return error }

        return switch stage {
        case .settings:
            .invalidSettings(error.localizedDescription)
        case .whisper:
            .whisperModelLoadFailed(error.localizedDescription)
        case .audio:
            .captureFailed(error.localizedDescription)
        }
    }

    private func isCurrentSession(_ expectedSessionID: UUID) -> Bool {
        sessionID == expectedSessionID
    }

    private func startPerformancePublishing(
        tracker: PipelinePerformanceTracker,
        sessionID expectedSessionID: UUID,
        handler: @escaping PerformanceDiagnosticsHandler
    ) {
        let sampler = processMetricsSampler
        performanceTask = Task { [weak self] in
            while !Task.isCancelled {
                let resourceSample = await sampler.sample()
                tracker.updateResources(resourceSample)
                let diagnostics = tracker.snapshot()
                guard self?.isCurrentSession(expectedSessionID) == true else { return }
                await handler(diagnostics)

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func performanceErrorCategory(_ error: any Error) -> String {
        if error is MLingoError { return "mlingo" }
        if error is URLError { return "network" }
        return "other"
    }
}

private enum StartStage {
    case settings
    case whisper
    case audio
}
