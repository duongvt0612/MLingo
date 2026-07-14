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
    private var pendingWindow: AudioChunk?
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

        pendingWindow = nil
    }

    public func ingest(_ chunk: AudioChunk) {
        guard let sessionID else { return }

        silenceTask?.cancel()
        let windows = accumulator.append(chunk)
        for window in windows {
            enqueue(window, sessionID: sessionID)
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
        processingTask?.cancel()
        processingTask = nil
        pendingWindow = nil
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
            enqueue(window, sessionID: expectedSessionID)
        }
    }

    private func enqueue(_ window: AudioChunk, sessionID expectedSessionID: UUID) {
        guard sessionID == expectedSessionID else { return }

        if processingTask == nil {
            processingTask = Task { [weak self] in
                await self?.processWindows(
                    startingWith: window,
                    sessionID: expectedSessionID
                )
            }
            return
        }

        if let pendingWindow {
            self.pendingWindow = Self.coalesce(
                pendingWindow,
                with: window,
                maximumDuration: configuration.maximumWindowDuration
            )
        } else {
            pendingWindow = window
        }
    }

    private func processWindows(
        startingWith firstWindow: AudioChunk,
        sessionID expectedSessionID: UUID
    ) async {
        defer {
            if sessionID == expectedSessionID {
                processingTask = nil
            }
        }

        var nextWindow: AudioChunk? = firstWindow
        while let window = nextWindow,
              sessionID == expectedSessionID,
              !Task.isCancelled
        {
            await process(window, sessionID: expectedSessionID)
            guard sessionID == expectedSessionID, !Task.isCancelled else { return }
            nextWindow = pendingWindow
            pendingWindow = nil
        }
    }

    private static func coalesce(
        _ older: AudioChunk,
        with newer: AudioChunk,
        maximumDuration: TimeInterval
    ) -> AudioChunk {
        guard
            older.sampleRate == newer.sampleRate,
            older.channelCount == newer.channelCount,
            older.sampleRate > 0
        else {
            return newer
        }

        let sampleRate = older.sampleRate
        let olderEnd = older.timestamp + older.duration
        var combinedSamples = older.samples

        if newer.timestamp >= olderEnd {
            let gapSampleCount = Int(((newer.timestamp - olderEnd) * sampleRate).rounded())
            if gapSampleCount > 0 {
                combinedSamples.append(contentsOf: repeatElement(0, count: gapSampleCount))
            }
            combinedSamples.append(contentsOf: newer.samples)
        } else {
            let overlapSampleCount = min(
                newer.samples.count,
                max(0, Int(((olderEnd - newer.timestamp) * sampleRate).rounded()))
            )
            combinedSamples.append(contentsOf: newer.samples.dropFirst(overlapSampleCount))
        }

        let maximumSampleCount = max(1, Int((maximumDuration * sampleRate).rounded()))
        if combinedSamples.count > maximumSampleCount {
            combinedSamples.removeFirst(combinedSamples.count - maximumSampleCount)
        }

        let duration = Double(combinedSamples.count) / sampleRate
        let combinedEnd = max(olderEnd, newer.timestamp + newer.duration)
        return AudioChunk(
            samples: combinedSamples,
            sampleRate: sampleRate,
            channelCount: older.channelCount,
            timestamp: combinedEnd - duration,
            duration: duration
        )
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
