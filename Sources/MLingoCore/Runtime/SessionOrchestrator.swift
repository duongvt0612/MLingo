import Foundation

@MainActor
public final class SessionOrchestrator: SessionRuntimeProtocol {
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
    private let eventHub: TypedEventHub
    private let makeSessionID: @Sendable () -> SessionID

    private var task: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var performanceTask: Task<Void, Never>?
    private var activeAudioEngine: (any AudioEngineProtocol)?
    private var sessionID: SessionID?
    private var sessionStarted = false
    private var activeMode: SessionKind?
    private var overlayVisible = false
    private var performanceTracker: PipelinePerformanceTracker?
    private var diagnosticsSubscriber: SessionDiagnosticsSubscriber?
    private var subscriptionTokens: [SubscriptionToken] = []
    private var translationWorker: TranslationWorker?
    private var translatedSubtitleSink: TranslatedSubtitleSink?

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
            now: { .now },
            eventHub: TypedEventHub(),
            makeSessionID: { SessionID(rawValue: UUID()) }
        )
    }

    init(
        audioEngineFactory: any AudioEngineFactoryProtocol,
        whisperEngine: WhisperEngineProtocol,
        translationEngine: TranslationEngineProtocol,
        overlayEngine: OverlayEngineProtocol,
        settingsStore: SettingsStoreProtocol,
        processMetricsSampler: any ProcessMetricsSampling,
        now: @escaping PerformanceNow,
        eventHub: TypedEventHub = TypedEventHub(),
        makeSessionID: @escaping @Sendable () -> SessionID = {
            SessionID(rawValue: UUID())
        }
    ) {
        self.audioEngineFactory = audioEngineFactory
        self.translationEngine = translationEngine
        self.overlayEngine = overlayEngine
        self.settingsStore = settingsStore
        self.processMetricsSampler = processMetricsSampler
        self.now = now
        self.eventHub = eventHub
        self.makeSessionID = makeSessionID
        transcriptionCoordinator = WhisperTranscriptionCoordinator(
            engine: whisperEngine,
            configuration: AdaptiveAudioWindowConfiguration(),
            now: now
        )
    }

    @discardableResult
    public func start(
        kind: SessionKind,
        translationSelection: ResolvedProviderSelection?,
        handlers: SessionRuntimeHandlers
    ) async -> Bool {
        await start(
            kind: kind,
            translationSelection: translationSelection,
            onError: handlers.onError,
            onWarning: handlers.onWarning,
            onAudioDiagnostics: handlers.onAudioDiagnostics,
            onTranscript: handlers.onTranscript,
            onWhisperDiagnostics: handlers.onWhisperDiagnostics,
            onPerformanceDiagnostics: handlers.onPerformanceDiagnostics
        )
    }

    @discardableResult
    public func start(
        kind: SessionKind = .translation,
        translationSelection: ResolvedProviderSelection? = nil,
        onError: @escaping ErrorHandler,
        onWarning: @escaping @Sendable (String) -> Void = { _ in },
        onAudioDiagnostics: (@Sendable (AudioCaptureDiagnostics) async -> Void)? = nil,
        onTranscript: @escaping TranscriptHandler = { _ in },
        onWhisperDiagnostics: @escaping WhisperDiagnosticsHandler = { _ in },
        onPerformanceDiagnostics: @escaping PerformanceDiagnosticsHandler = { _ in }
    ) async -> Bool {
        MLingoLogger.pipeline.info("Starting session orchestrator")
        await stop(reason: .cancelled)

        let newSessionID = makeSessionID()
        sessionID = newSessionID
        sessionStarted = false
        activeMode = kind
        let tracker = PipelinePerformanceTracker(now: now)
        performanceTracker = tracker
        let diagnosticsSubscriber = SessionDiagnosticsSubscriber(
            onAudioDiagnostics: onAudioDiagnostics ?? { _ in },
            onWhisperDiagnostics: onWhisperDiagnostics,
            onPerformanceDiagnostics: onPerformanceDiagnostics
        )
        self.diagnosticsSubscriber = diagnosticsSubscriber
        await diagnosticsSubscriber.receivePerformance(PipelinePerformanceDiagnostics())

        var startStage = StartStage.settings
        do {
            let settings = try await settingsStore.load()
            startStage = .runtime
            try await configureEventRoutes(
                kind: kind,
                settings: settings,
                translationSelection: translationSelection,
                sessionID: newSessionID,
                onTranscript: onTranscript,
                onError: onError,
                onWarning: onWarning
            )
            startStage = .whisper
            try await transcriptionCoordinator.start(
                modelID: settings.whisperModel,
                language: settings.sourceLanguage,
                onTranscript: { [weak self] transcript in
                    await self?.publishTranscript(
                        transcript,
                        sessionID: newSessionID,
                        onError: onError
                    )
                },
                onDiagnostics: { diagnostics in
                    await diagnosticsSubscriber.receiveWhisper(diagnostics)
                },
                onError: { [weak self] message in
                    await self?.failRuntime(
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

            _ = try await eventHub.publish(
                SessionStarted(kind: kind),
                sessionID: newSessionID
            )
            sessionStarted = true

            if kind == .translation {
                overlayEngine.show(settings: settings)
                overlayVisible = true
            }
            MLingoLogger.pipeline.info("Session orchestrator started")

            if onAudioDiagnostics != nil {
                diagnosticsTask = Task { [weak self, audioEngine] in
                    for await diagnostics in audioEngine.diagnostics {
                        if Task.isCancelled { return }
                        guard self?.isCurrentSession(newSessionID) == true else { return }
                        await diagnosticsSubscriber.receiveAudio(diagnostics)
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
                diagnosticsSubscriber: diagnosticsSubscriber
            )
            return true
        } catch is CancellationError {
            if sessionID == newSessionID {
                await stop(reason: .cancelled)
            }
            return false
        } catch {
            guard sessionID == newSessionID else { return false }
            MLingoLogger.pipeline.error(
                "Session orchestrator failed to start: \(error.localizedDescription, privacy: .public)"
            )
            onError(Self.startError(error, stage: startStage))
            await stop(reason: .cancelled)
            return false
        }
    }

    public func stop() async {
        await stop(reason: .cancelled)
    }

    public func stop(reason: SessionEndReason) async {
        MLingoLogger.pipeline.info("Stopping session orchestrator")
        let stoppedSessionID = sessionID
        let shouldPublishSessionEnd = sessionStarted
        sessionID = nil
        sessionStarted = false
        activeMode = nil
        task?.cancel()
        task = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        performanceTask?.cancel()
        let stoppedPerformanceTask = performanceTask
        performanceTask = nil
        let stoppedPerformanceTracker = performanceTracker
        let audioEngine = activeAudioEngine
        activeAudioEngine = nil
        let stoppedWorker = translationWorker
        translationWorker = nil
        translatedSubtitleSink = nil
        let stoppedTokens = subscriptionTokens
        subscriptionTokens.removeAll(keepingCapacity: false)
        for token in stoppedTokens {
            await eventHub.cancel(token)
        }
        await stoppedWorker?.cancel()
        await transcriptionCoordinator.stop()
        await audioEngine?.stop()
        await stoppedPerformanceTask?.value
        stoppedPerformanceTracker?.updateTranslationQueue(depth: 0)
        performanceTracker = nil
        let stoppedDiagnosticsSubscriber = diagnosticsSubscriber
        diagnosticsSubscriber = nil
        if overlayVisible {
            overlayEngine.hide()
            overlayVisible = false
        }
        if let stoppedDiagnosticsSubscriber {
            await stoppedDiagnosticsSubscriber.receivePerformance(
                stoppedPerformanceTracker?.snapshot() ?? PipelinePerformanceDiagnostics()
            )
        }
        if shouldPublishSessionEnd, let stoppedSessionID {
            do {
                _ = try await eventHub.publish(
                    SessionEnded(reason: reason),
                    sessionID: stoppedSessionID
                )
            } catch {
                MLingoLogger.pipeline.error(
                    "Failed to publish session end: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        MLingoLogger.pipeline.info("Session orchestrator stopped")
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

    private func configureEventRoutes(
        kind: SessionKind,
        settings: AppSettings,
        translationSelection: ResolvedProviderSelection?,
        sessionID expectedSessionID: SessionID,
        onTranscript: @escaping TranscriptHandler,
        onError: @escaping ErrorHandler,
        onWarning: @escaping @Sendable (String) -> Void
    ) async throws {
        let worker: TranslationWorker?
        if kind == .translation {
            let createdWorker = TranslationWorker(
            translationEngine: translationEngine,
            settings: settings,
            selection: translationSelection,
            eventHub: eventHub,
            sessionID: expectedSessionID,
            observers: TranslationWorkerObservers(
                onQueued: { [weak self] transcriptID in
                    await self?.recordTranslationQueued(
                        transcriptID,
                        sessionID: expectedSessionID
                    )
                },
                onStarted: { [weak self] transcriptID in
                    await self?.recordTranslationStarted(
                        transcriptID,
                        sessionID: expectedSessionID
                    )
                },
                onFinished: { [weak self] transcriptID in
                    await self?.recordTranslationFinished(
                        transcriptID,
                        sessionID: expectedSessionID
                    )
                },
                onDiscarded: { [weak self] transcriptID, duplicate, skipped in
                    await self?.discardTranslationTrace(
                        transcriptID,
                        duplicate: duplicate,
                        skipped: skipped,
                        sessionID: expectedSessionID
                    )
                },
                onQueueDepth: { [weak self] depth in
                    await self?.updateTranslationQueue(
                        depth,
                        sessionID: expectedSessionID
                    )
                },
                onWarning: onWarning,
                onError: { [weak self] error in
                    await self?.reportError(
                        error,
                        sessionID: expectedSessionID,
                        handler: onError
                    )
                },
                onFatalError: { [weak self] error in
                    await self?.failRuntime(
                        error,
                        sessionID: expectedSessionID,
                        handler: onError
                    )
                }
            )
            )
            worker = createdWorker
            translationWorker = createdWorker
            translatedSubtitleSink = TranslatedSubtitleSink(
                overlayEngine: overlayEngine,
                settings: settings,
                now: now,
                onDiscarded: { [weak self] transcriptID in
                    guard self?.sessionID == expectedSessionID else { return }
                    self?.performanceTracker?.discardTrace(transcriptID: transcriptID)
                },
                onRendered: { [weak self] transcriptID, startedAt, endedAt in
                    guard self?.sessionID == expectedSessionID else { return }
                    self?.performanceTracker?.recordOverlayRendered(
                        transcriptID: transcriptID,
                        startedAt: startedAt,
                        endedAt: endedAt
                    )
                }
            )
            let translationToken = try await eventHub.subscribe(
                to: TranslationCompleted.self,
                scope: .session(expectedSessionID),
                delivery: .durable(capacity: 16)
            ) { [weak self] envelope in
                await self?.deliverTranslation(
                    envelope,
                    sessionID: expectedSessionID
                )
            }
            subscriptionTokens.append(translationToken)
        } else {
            worker = nil
        }

        let router = SessionTranscriptRouter(
            sessionID: expectedSessionID,
            originalSink: OriginalSubtitleSink(handler: onTranscript),
            translationWorker: worker,
            isSessionActive: { [weak self] in
                await self?.isCurrentSession(expectedSessionID) == true
            },
            onTranscriptionComplete: { [weak self] transcriptID in
                await self?.discardTranslationTrace(
                    transcriptID,
                    duplicate: false,
                    skipped: false,
                    sessionID: expectedSessionID
                )
            }
        )
        let transcriptToken = try await eventHub.subscribe(
            to: TranscriptCompleted.self,
            scope: .session(expectedSessionID),
            delivery: .durable(capacity: 16)
        ) { envelope in
            await router.route(envelope)
        }
        subscriptionTokens.append(transcriptToken)
    }

    private func publishTranscript(
        _ transcript: Transcript,
        sessionID expectedSessionID: SessionID,
        onError: @escaping ErrorHandler
    ) async {
        guard sessionID == expectedSessionID else { return }
        let traceID = TraceID(
            rawValue: performanceTracker?.traceID(for: transcript.id) ?? transcript.id
        )
        do {
            _ = try await eventHub.publish(
                TranscriptCompleted(transcript: transcript),
                sessionID: expectedSessionID,
                traceID: traceID
            )
        } catch {
            await failRuntime(
                .translationFailed("Event hub publication failed."),
                sessionID: expectedSessionID,
                handler: onError
            )
        }
    }

    private func deliverTranslation(
        _ envelope: EventEnvelope<TranslationCompleted>,
        sessionID expectedSessionID: SessionID
    ) {
        guard sessionID == expectedSessionID else { return }
        translatedSubtitleSink?.receive(envelope)
    }

    private func recordTranslationQueued(
        _ transcriptID: UUID,
        sessionID expectedSessionID: SessionID
    ) {
        guard sessionID == expectedSessionID else { return }
        performanceTracker?.recordTranslationQueued(transcriptID: transcriptID, at: now())
    }

    private func recordTranslationStarted(
        _ transcriptID: UUID,
        sessionID expectedSessionID: SessionID
    ) {
        guard sessionID == expectedSessionID else { return }
        performanceTracker?.recordTranslationStarted(transcriptID: transcriptID, at: now())
    }

    private func recordTranslationFinished(
        _ transcriptID: UUID,
        sessionID expectedSessionID: SessionID
    ) {
        guard sessionID == expectedSessionID else { return }
        performanceTracker?.recordTranslationFinished(transcriptID: transcriptID, at: now())
    }

    private func discardTranslationTrace(
        _ transcriptID: UUID,
        duplicate: Bool,
        skipped: Bool,
        sessionID expectedSessionID: SessionID
    ) {
        guard sessionID == expectedSessionID else { return }
        performanceTracker?.discardTrace(
            transcriptID: transcriptID,
            duplicate: duplicate,
            skipped: skipped
        )
    }

    private func updateTranslationQueue(
        _ depth: Int,
        sessionID expectedSessionID: SessionID
    ) {
        guard sessionID == expectedSessionID else { return }
        performanceTracker?.updateTranslationQueue(depth: depth)
    }

    private func failRuntime(
        _ error: MLingoError,
        sessionID expectedSessionID: SessionID,
        handler: @escaping ErrorHandler
    ) async {
        guard sessionID == expectedSessionID else { return }
        handler(error)
        Task { @MainActor [weak self] in
            guard self?.sessionID == expectedSessionID else { return }
            await self?.stop(reason: .failed)
        }
    }

    private func reportError(
        _ error: MLingoError,
        sessionID expectedSessionID: SessionID,
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
        case .runtime:
            .translationFailed("Event runtime failed to start.")
        case .whisper:
            .whisperModelLoadFailed(error.localizedDescription)
        case .audio:
            .captureFailed(error.localizedDescription)
        }
    }

    private func isCurrentSession(_ expectedSessionID: SessionID) -> Bool {
        sessionID == expectedSessionID
    }

    private func startPerformancePublishing(
        tracker: PipelinePerformanceTracker,
        sessionID expectedSessionID: SessionID,
        diagnosticsSubscriber: SessionDiagnosticsSubscriber
    ) {
        let sampler = processMetricsSampler
        performanceTask = Task { [weak self] in
            while !Task.isCancelled {
                let resourceSample = await sampler.sample()
                tracker.updateResources(resourceSample)
                let diagnostics = tracker.snapshot()
                guard self?.isCurrentSession(expectedSessionID) == true else { return }
                await diagnosticsSubscriber.receivePerformance(diagnostics)

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

}

private enum StartStage {
    case settings
    case runtime
    case whisper
    case audio
}
