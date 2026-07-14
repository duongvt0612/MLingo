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
    private var pendingWindows: [AudioChunk] = []
    private var latestProcessedAudioEnd: TimeInterval?
    private var preRollChunks: [AudioChunk] = []
    private var preRollDuration: TimeInterval = 0
    private var hasActiveSpeech = false
    private var activeSpeechDuration: TimeInterval = 0

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
        resetSpeechSegmentation()
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

        pendingWindows.removeAll(keepingCapacity: true)
    }

    public func ingest(_ chunk: AudioChunk) {
        guard let sessionID else { return }

        if chunk.isSpeechLike {
            silenceTask?.cancel()
            if !hasActiveSpeech {
                hasActiveSpeech = true
                for preRollChunk in preRollChunks {
                    append(preRollChunk, sessionID: sessionID)
                }
                clearPreRoll()
            }
            append(chunk, sessionID: sessionID)
            activeSpeechDuration += chunk.duration
            scheduleSilenceFlush(sessionID: sessionID)
        } else if hasActiveSpeech {
            append(chunk, sessionID: sessionID)
        } else {
            retainPreRoll(chunk)
        }
    }

    private func scheduleSilenceFlush(sessionID: UUID) {
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
        pendingWindows.removeAll(keepingCapacity: true)
        accumulator.reset()
        deduplicator.reset()
        latestProcessedAudioEnd = nil
        resetSpeechSegmentation()
        transcriptHandler = nil
        diagnosticsHandler = nil
        errorHandler = nil
    }

    private func flushForSilence(sessionID expectedSessionID: UUID) {
        guard sessionID == expectedSessionID else { return }
        if activeSpeechDuration >= configuration.minimumSpeechDuration,
           let window = accumulator.flushForSilence()
        {
            enqueue(window, sessionID: expectedSessionID)
        } else {
            accumulator.reset()
        }
        hasActiveSpeech = false
        activeSpeechDuration = 0
    }

    private func append(_ chunk: AudioChunk, sessionID: UUID) {
        let windows = accumulator.append(chunk)
        for window in windows {
            enqueue(window, sessionID: sessionID)
        }
    }

    private func retainPreRoll(_ chunk: AudioChunk) {
        let maximumDuration = configuration.overlapDuration
        guard maximumDuration > 0 else { return }

        preRollChunks.append(chunk)
        preRollDuration += chunk.duration
        while preRollDuration > maximumDuration, let firstChunk = preRollChunks.first {
            let excessDuration = preRollDuration - maximumDuration
            if excessDuration >= firstChunk.duration {
                preRollChunks.removeFirst()
                preRollDuration -= firstChunk.duration
                continue
            }

            let dropSampleCount = min(
                firstChunk.samples.count,
                max(1, Int((excessDuration * firstChunk.sampleRate).rounded()))
            )
            let retainedSamples = Array(firstChunk.samples.dropFirst(dropSampleCount))
            let droppedDuration = Double(dropSampleCount) / firstChunk.sampleRate
            preRollChunks[0] = AudioChunk(
                samples: retainedSamples,
                sampleRate: firstChunk.sampleRate,
                channelCount: firstChunk.channelCount,
                timestamp: firstChunk.timestamp + droppedDuration,
                duration: Double(retainedSamples.count) / firstChunk.sampleRate,
                isSpeechLike: false
            )
            preRollDuration -= droppedDuration
        }
    }

    private func clearPreRoll() {
        preRollChunks.removeAll(keepingCapacity: true)
        preRollDuration = 0
    }

    private func resetSpeechSegmentation() {
        clearPreRoll()
        hasActiveSpeech = false
        activeSpeechDuration = 0
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

        if let lastWindow = pendingWindows.last,
           let coalescedWindow = Self.coalesceWithoutDropping(
               lastWindow,
               with: window,
               maximumDuration: configuration.maximumWindowDuration
           )
        {
            pendingWindows[pendingWindows.count - 1] = coalescedWindow
        } else {
            pendingWindows.append(window)
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
            nextWindow = pendingWindows.isEmpty ? nil : pendingWindows.removeFirst()
        }
    }

    private static func coalesceWithoutDropping(
        _ older: AudioChunk,
        with newer: AudioChunk,
        maximumDuration: TimeInterval
    ) -> AudioChunk? {
        guard
            older.sampleRate == newer.sampleRate,
            older.channelCount == newer.channelCount,
            older.sampleRate > 0
        else {
            return nil
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
        guard combinedSamples.count <= maximumSampleCount else { return nil }

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
