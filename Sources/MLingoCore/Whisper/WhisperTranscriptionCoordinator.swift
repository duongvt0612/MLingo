import Foundation

public actor WhisperTranscriptionCoordinator {
    public typealias TranscriptHandler = @Sendable (Transcript) async -> Void
    public typealias DiagnosticsHandler = @Sendable (WhisperDiagnostics) async -> Void
    public typealias ErrorHandler = @Sendable (String) async -> Void

    private let engine: WhisperEngineProtocol
    private let configuration: AdaptiveAudioWindowConfiguration
    private var accumulator: AdaptiveAudioWindowAccumulator
    private var deduplicator = TranscriptDeduplicator()
    private var diagnostics = WhisperDiagnostics()
    private var sessionID: UUID?
    private var language = ""
    private var transcriptHandler: TranscriptHandler?
    private var diagnosticsHandler: DiagnosticsHandler?
    private var errorHandler: ErrorHandler?
    private var silenceTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var windowContinuation: AsyncStream<AudioChunk>.Continuation?
    private var latestProcessedAudioEnd: TimeInterval?

    public init(engine: WhisperEngineProtocol) {
        let configuration = AdaptiveAudioWindowConfiguration()
        self.engine = engine
        self.configuration = configuration
        accumulator = AdaptiveAudioWindowAccumulator(configuration: configuration)
    }

    init(
        engine: WhisperEngineProtocol,
        configuration: AdaptiveAudioWindowConfiguration
    ) {
        self.engine = engine
        self.configuration = configuration
        accumulator = AdaptiveAudioWindowAccumulator(configuration: configuration)
    }

    public func start(
        modelID: String,
        language: String,
        onTranscript: @escaping TranscriptHandler,
        onDiagnostics: @escaping DiagnosticsHandler = { _ in },
        onError: @escaping ErrorHandler = { _ in }
    ) async throws {
        stop()

        let newSessionID = UUID()
        sessionID = newSessionID
        self.language = language
        transcriptHandler = onTranscript
        diagnosticsHandler = onDiagnostics
        errorHandler = onError
        accumulator = AdaptiveAudioWindowAccumulator(configuration: configuration)
        deduplicator.reset()
        latestProcessedAudioEnd = nil
        diagnostics = WhisperDiagnostics(modelState: .loading, modelID: modelID)
        await onDiagnostics(diagnostics)

        do {
            try await engine.loadModel(named: modelID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard sessionID == newSessionID else { throw CancellationError() }
            diagnostics.modelState = .failed(error.localizedDescription)
            await onDiagnostics(diagnostics)
            throw error
        }

        guard sessionID == newSessionID else { throw CancellationError() }
        diagnostics.modelState = .ready
        await onDiagnostics(diagnostics)

        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        windowContinuation = continuation
        processingTask = Task { [weak self] in
            for await window in stream {
                guard !Task.isCancelled else { return }
                await self?.process(window, sessionID: newSessionID)
            }
        }
    }

    public func ingest(_ chunk: AudioChunk) {
        guard let sessionID else { return }

        silenceTask?.cancel()
        let windows = accumulator.append(chunk)
        for window in windows {
            windowContinuation?.yield(window)
        }

        let delay = configuration.silenceFlushDelay
        silenceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            await self?.flushForSilence(sessionID: sessionID)
        }
    }

    public func stop() {
        sessionID = nil
        silenceTask?.cancel()
        silenceTask = nil
        windowContinuation?.finish()
        windowContinuation = nil
        processingTask?.cancel()
        processingTask = nil
        accumulator.reset()
        deduplicator.reset()
        latestProcessedAudioEnd = nil
        transcriptHandler = nil
        diagnosticsHandler = nil
        errorHandler = nil
    }

    private func flushForSilence(sessionID expectedSessionID: UUID) {
        guard sessionID == expectedSessionID else { return }
        if let window = accumulator.flushForSilence() {
            windowContinuation?.yield(window)
        }
    }

    private func process(_ window: AudioChunk, sessionID expectedSessionID: UUID) async {
        guard sessionID == expectedSessionID else { return }
        let start = ContinuousClock.now

        do {
            let transcript = try await engine.transcribe(window, language: language)
            let latency = start.duration(to: .now).timeInterval

            guard sessionID == expectedSessionID, !Task.isCancelled else { return }
            diagnostics.processedWindowCount += 1
            diagnostics.windowDuration = window.duration
            diagnostics.inferenceLatency = latency

            if let transcript {
                let timestamp = max(
                    transcript.timestamp,
                    latestProcessedAudioEnd ?? transcript.timestamp
                )
                let timestampedTranscript = Transcript(
                    id: transcript.id,
                    text: transcript.text,
                    timestamp: timestamp
                )
                let emittedTranscript = deduplicator.process(timestampedTranscript)
                diagnostics.suppressedDuplicateCount = deduplicator.suppressedCount
                if let emittedTranscript {
                    diagnostics.lastTranscript = emittedTranscript.text
                    if let transcriptHandler {
                        await transcriptHandler(emittedTranscript)
                    }
                }
            }
            latestProcessedAudioEnd = max(
                latestProcessedAudioEnd ?? window.timestamp,
                window.timestamp + window.duration
            )

            if let diagnosticsHandler {
                await diagnosticsHandler(diagnostics)
            }
        } catch is CancellationError {
            return
        } catch {
            guard sessionID == expectedSessionID, !Task.isCancelled else { return }
            diagnostics.modelState = .failed(error.localizedDescription)
            if let diagnosticsHandler {
                await diagnosticsHandler(diagnostics)
            }
            if let errorHandler {
                await errorHandler(error.localizedDescription)
            }
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
