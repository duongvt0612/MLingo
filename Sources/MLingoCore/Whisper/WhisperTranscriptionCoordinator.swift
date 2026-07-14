import Foundation

private enum WhisperCoordinatorTaskContext {
    @TaskLocal static var processingSessionID: UUID?
}

public actor WhisperTranscriptionCoordinator {
    public typealias TranscriptHandler = @Sendable (Transcript) async -> Void
    public typealias DiagnosticsHandler = @Sendable (WhisperDiagnostics) async -> Void
    public typealias ErrorHandler = @Sendable (String) async -> Void

    private let engine: WhisperEngineProtocol
    private let configuration: AdaptiveAudioWindowConfiguration
    private let maximumPendingWindowDuration: TimeInterval
    private var accumulator: AdaptiveAudioWindowAccumulator
    private var deduplicator = TranscriptDeduplicator()
    private var diagnostics = WhisperDiagnostics()
    private var sessionID: UUID?
    private var acceptingAudio = false
    private var language = ""
    private var transcriptHandler: TranscriptHandler?
    private var diagnosticsHandler: DiagnosticsHandler?
    private var errorHandler: ErrorHandler?
    private var silenceTask: Task<Void, Never>?
    private var modelLoadingTask: Task<Void, Error>?
    private var processingTask: Task<Void, Never>?
    private var pendingWindows: [AudioChunk] = []
    private var latestProcessedAudioEnd: TimeInterval?
    private var preRollChunks: [AudioChunk] = []
    private var preRollDuration: TimeInterval = 0
    private var hasActiveSpeech = false
    private var activeSpeechDuration: TimeInterval = 0
    private var latestStartRequestID: UUID?

    public init(engine: WhisperEngineProtocol) {
        let configuration = AdaptiveAudioWindowConfiguration()
        self.engine = engine
        self.configuration = configuration
        maximumPendingWindowDuration = configuration.maximumWindowDuration * 3
        accumulator = AdaptiveAudioWindowAccumulator(configuration: configuration)
    }

    init(
        engine: WhisperEngineProtocol,
        configuration: AdaptiveAudioWindowConfiguration,
        maximumPendingWindowDuration: TimeInterval? = nil
    ) {
        let pendingDuration = maximumPendingWindowDuration
            ?? configuration.maximumWindowDuration * 3
        precondition(pendingDuration >= configuration.maximumWindowDuration)
        self.engine = engine
        self.configuration = configuration
        self.maximumPendingWindowDuration = pendingDuration
        accumulator = AdaptiveAudioWindowAccumulator(configuration: configuration)
    }

    public func start(
        modelID: String,
        language: String,
        onTranscript: @escaping TranscriptHandler,
        onDiagnostics: @escaping DiagnosticsHandler = { _ in },
        onError: @escaping ErrorHandler = { _ in }
    ) async throws {
        let startRequestID = UUID()
        latestStartRequestID = startRequestID
        await stopCurrentSession()
        guard latestStartRequestID == startRequestID else { throw CancellationError() }

        let newSessionID = UUID()
        sessionID = newSessionID
        acceptingAudio = false
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
        guard sessionID == newSessionID,
              latestStartRequestID == startRequestID,
              !Task.isCancelled
        else {
            throw CancellationError()
        }

        let loadingTask = Task { [engine] in
            try await engine.loadModel(named: modelID)
        }
        modelLoadingTask = loadingTask

        do {
            try await loadingTask.value
            if sessionID == newSessionID {
                modelLoadingTask = nil
            }
        } catch is CancellationError {
            if sessionID == newSessionID {
                latestStartRequestID = nil
                await stopCurrentSession()
            }
            throw CancellationError()
        } catch {
            guard sessionID == newSessionID else { throw CancellationError() }
            diagnostics.modelState = .failed(error.localizedDescription)
            await onDiagnostics(diagnostics)
            guard sessionID == newSessionID else { throw CancellationError() }
            latestStartRequestID = nil
            await stopCurrentSession()
            throw error
        }

        guard sessionID == newSessionID,
              latestStartRequestID == startRequestID,
              !Task.isCancelled
        else {
            throw CancellationError()
        }
        acceptingAudio = true
        diagnostics.modelState = .ready
        await onDiagnostics(diagnostics)
        guard sessionID == newSessionID,
              latestStartRequestID == startRequestID,
              !Task.isCancelled
        else {
            throw CancellationError()
        }
    }

    public func ingest(_ chunk: AudioChunk) {
        guard acceptingAudio,
              let sessionID,
              let chunkDuration = Self.sampleDuration(of: chunk)
        else {
            return
        }

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
            activeSpeechDuration += chunkDuration
            scheduleSilenceFlush(sessionID: sessionID)
        } else if hasActiveSpeech {
            append(chunk, sessionID: sessionID)
        } else {
            retainPreRoll(chunk, duration: chunkDuration)
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

    public func stop() async {
        latestStartRequestID = nil
        await stopCurrentSession()
    }

    private func stopCurrentSession() async {
        let stoppedSessionID = sessionID
        acceptingAudio = false
        sessionID = nil
        silenceTask?.cancel()
        silenceTask = nil
        let loadingTask = modelLoadingTask
        modelLoadingTask = nil
        loadingTask?.cancel()
        let inferenceTask = processingTask
        processingTask = nil
        let isCurrentInferenceTask = WhisperCoordinatorTaskContext.processingSessionID
            == stoppedSessionID
        if !isCurrentInferenceTask {
            inferenceTask?.cancel()
        }

        if let loadingTask {
            _ = await loadingTask.result
        }
        if !isCurrentInferenceTask {
            await inferenceTask?.value
        }

        guard sessionID == nil else { return }
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
        guard acceptingAudio, sessionID == expectedSessionID else { return }
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
        guard acceptingAudio, self.sessionID == sessionID else { return }
        let windows = accumulator.append(chunk)
        for window in windows {
            enqueue(window, sessionID: sessionID)
        }
    }

    private func retainPreRoll(_ chunk: AudioChunk, duration chunkDuration: TimeInterval) {
        let maximumDuration = configuration.overlapDuration
        guard maximumDuration > 0 else { return }

        preRollChunks.append(chunk)
        preRollDuration += chunkDuration
        while preRollDuration > maximumDuration, let firstChunk = preRollChunks.first {
            guard let firstChunkDuration = Self.sampleDuration(of: firstChunk) else {
                preRollChunks.removeFirst()
                continue
            }
            let excessDuration = preRollDuration - maximumDuration
            if excessDuration >= firstChunkDuration {
                preRollChunks.removeFirst()
                preRollDuration -= firstChunkDuration
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
        guard acceptingAudio, sessionID == expectedSessionID else { return }

        if processingTask == nil {
            processingTask = Task { [weak self] in
                await WhisperCoordinatorTaskContext.$processingSessionID.withValue(
                    expectedSessionID
                ) {
                    await self?.processWindows(
                        startingWith: window,
                        sessionID: expectedSessionID
                    )
                }
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
            appendPendingWindow(window)
        }
    }

    private func appendPendingWindow(_ window: AudioChunk) {
        while !pendingWindows.isEmpty,
              pendingWindows.reduce(0, { $0 + $1.duration }) + window.duration
                > maximumPendingWindowDuration
        {
            pendingWindows.removeFirst()
            diagnostics.droppedBacklogWindowCount += 1
        }

        guard window.duration <= maximumPendingWindowDuration else {
            diagnostics.droppedBacklogWindowCount += 1
            return
        }
        pendingWindows.append(window)
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
              acceptingAudio,
              sessionID == expectedSessionID,
              !Task.isCancelled
        {
            await process(window, sessionID: expectedSessionID)
            guard sessionID == expectedSessionID, !Task.isCancelled else { return }
            nextWindow = pendingWindows.isEmpty ? nil : pendingWindows.removeFirst()
        }
    }

    static func coalesceWithoutDropping(
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
        let maximumSampleCount = max(1, Int((maximumDuration * sampleRate).rounded()))
        guard olderEnd.isFinite,
              newer.timestamp.isFinite,
              older.samples.count <= maximumSampleCount
        else {
            return nil
        }
        var combinedSamples = older.samples
        var remainingCapacity = maximumSampleCount - combinedSamples.count

        if newer.timestamp >= olderEnd {
            let gapSamples = ((newer.timestamp - olderEnd) * sampleRate).rounded()
            guard gapSamples.isFinite,
                  gapSamples >= 0,
                  gapSamples <= Double(remainingCapacity)
            else {
                return nil
            }
            let gapSampleCount = Int(gapSamples)
            guard newer.samples.count <= remainingCapacity - gapSampleCount else {
                return nil
            }
            if gapSampleCount > 0 {
                combinedSamples.append(contentsOf: repeatElement(0, count: gapSampleCount))
            }
            combinedSamples.append(contentsOf: newer.samples)
        } else {
            let overlapSamples = ((olderEnd - newer.timestamp) * sampleRate).rounded()
            guard overlapSamples.isFinite,
                  overlapSamples >= 0,
                  overlapSamples <= Double(Int.max)
            else {
                return nil
            }
            let overlapSampleCount = min(
                newer.samples.count,
                Int(overlapSamples)
            )
            let nonOverlappingSamples = newer.samples.dropFirst(overlapSampleCount)
            guard nonOverlappingSamples.count <= remainingCapacity else { return nil }
            combinedSamples.append(contentsOf: nonOverlappingSamples)
        }

        remainingCapacity = maximumSampleCount - combinedSamples.count
        guard remainingCapacity >= 0 else { return nil }

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
        guard acceptingAudio, sessionID == expectedSessionID else { return }
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
                let audioOverlapDuration = max(
                    0,
                    (latestProcessedAudioEnd ?? window.timestamp) - window.timestamp
                )
                let emittedTranscript = deduplicator.process(
                    timestampedTranscript,
                    audioOverlapDuration: audioOverlapDuration
                )
                diagnostics.suppressedDuplicateCount = deduplicator.suppressedCount
                if let emittedTranscript {
                    diagnostics.lastTranscript = emittedTranscript.text
                    if let transcriptHandler {
                        await transcriptHandler(emittedTranscript)
                        guard sessionID == expectedSessionID, !Task.isCancelled else { return }
                    }
                }
            }
            latestProcessedAudioEnd = max(
                latestProcessedAudioEnd ?? window.timestamp,
                window.timestamp + window.duration
            )

            if let diagnosticsHandler {
                await diagnosticsHandler(diagnostics)
                guard sessionID == expectedSessionID, !Task.isCancelled else { return }
            }
        } catch is CancellationError {
            return
        } catch {
            guard sessionID == expectedSessionID, !Task.isCancelled else { return }
            diagnostics.modelState = .failed(error.localizedDescription)
            if let diagnosticsHandler {
                await diagnosticsHandler(diagnostics)
                guard sessionID == expectedSessionID, !Task.isCancelled else { return }
            }
            if let errorHandler {
                await errorHandler(error.localizedDescription)
                guard sessionID == expectedSessionID, !Task.isCancelled else { return }
            }
        }
    }

    private static func sampleDuration(of chunk: AudioChunk) -> TimeInterval? {
        guard chunk.sampleRate.isFinite,
              chunk.sampleRate > 0,
              chunk.channelCount == 1,
              !chunk.samples.isEmpty
        else {
            return nil
        }
        return Double(chunk.samples.count) / chunk.sampleRate
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
