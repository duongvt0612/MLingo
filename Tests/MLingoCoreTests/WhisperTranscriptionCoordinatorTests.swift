import Foundation
import Testing
@testable import MLingoCore

@Test
func coordinatorFlushesShortSpeechAfterSilence() async throws {
    let engine = SequencingWhisperEngine()
    let recorder = TranscriptRecorder()
    let coordinator = WhisperTranscriptionCoordinator(
        engine: engine,
        configuration: .init(silenceFlushDelay: 0.02)
    )

    try await coordinator.start(
        modelID: "fixture/whisper",
        language: "English",
        onTranscript: { transcript in
            await recorder.append(transcript)
        }
    )
    await coordinator.ingest(testAudioChunk(duration: 0.45, timestamp: 12))

    try await eventually {
        await recorder.count == 1
    }

    let transcript = try #require(await recorder.first)
    #expect(transcript.timestamp == 12)
    #expect(transcript.text == "window 1")
    await coordinator.stop()
}

@Test
func coordinatorPreservesQuietAudioAroundSpeechWithoutDeferringSilenceFlush() async throws {
    let engine = SequencingWhisperEngine()
    let coordinator = WhisperTranscriptionCoordinator(
        engine: engine,
        configuration: .init(
            minimumSpeechDuration: 0.1,
            preferredWindowDuration: 1,
            maximumWindowDuration: 2,
            silenceFlushDelay: 0.03,
            overlapDuration: 0.2
        )
    )

    try await coordinator.start(
        modelID: "fixture/whisper",
        language: "English",
        onTranscript: { _ in }
    )
    await coordinator.ingest(
        testAudioChunk(
            duration: 0.2,
            timestamp: 0,
            sampleValue: 0.001,
            isSpeechLike: false
        )
    )
    await coordinator.ingest(
        testAudioChunk(
            duration: 0.2,
            timestamp: 0.2,
            sampleValue: 0.05,
            isSpeechLike: true
        )
    )
    await coordinator.ingest(
        testAudioChunk(
            duration: 0.1,
            timestamp: 0.4,
            sampleValue: 0.001,
            isSpeechLike: false
        )
    )
    try await Task.sleep(for: .milliseconds(10))
    await coordinator.ingest(
        testAudioChunk(
            duration: 0.1,
            timestamp: 0.5,
            sampleValue: 0.001,
            isSpeechLike: false
        )
    )

    try await eventually {
        await engine.inferenceWindows.count == 1
    }
    let window = try #require(await engine.inferenceWindows.first)
    #expect(abs(window.timestamp - 0) < 0.001)
    #expect(abs(window.duration - 0.6) < 0.001)
    #expect(window.samples.first == 0.001)
    #expect(window.samples[Int(0.25 * 16_000)] == 0.05)
    #expect(window.samples.last == 0.001)
    await coordinator.stop()
}

@Test
func coordinatorDoesNotInferContinuousSilence() async throws {
    let engine = SequencingWhisperEngine()
    let coordinator = WhisperTranscriptionCoordinator(
        engine: engine,
        configuration: .init(silenceFlushDelay: 0.02)
    )
    try await coordinator.start(
        modelID: "fixture/whisper",
        language: "English",
        onTranscript: { _ in }
    )

    for index in 0..<10 {
        await coordinator.ingest(
            testAudioChunk(
                duration: 0.1,
                timestamp: Double(index) * 0.1,
                sampleValue: 0,
                isSpeechLike: false
            )
        )
    }
    try await Task.sleep(for: .milliseconds(40))

    #expect(await engine.inferenceWindows.isEmpty)
    await coordinator.stop()
}

@Test
func coordinatorSerializesInferenceAndReportsWindowDiagnostics() async throws {
    let engine = SequencingWhisperEngine(inferenceDelay: .milliseconds(20))
    let diagnosticsRecorder = DiagnosticsRecorder()
    let transcriptRecorder = TranscriptRecorder()
    let coordinator = WhisperTranscriptionCoordinator(engine: engine)

    try await coordinator.start(
        modelID: "fixture/whisper",
        language: "Vietnamese",
        onTranscript: { transcript in
            await transcriptRecorder.append(transcript)
        },
        onDiagnostics: { diagnostics in
            await diagnosticsRecorder.append(diagnostics)
        }
    )

    await coordinator.ingest(testAudioChunk(duration: 3, timestamp: 20))
    try await eventually {
        await diagnosticsRecorder.latest.processedWindowCount == 2
    }
    await coordinator.ingest(testAudioChunk(duration: 3, timestamp: 23))

    try await eventually {
        await diagnosticsRecorder.latest.processedWindowCount == 4
    }

    #expect(await engine.maximumConcurrentInferenceCount == 1)
    let latest = await diagnosticsRecorder.latest
    #expect(latest.modelState == .ready)
    #expect(latest.modelID == "fixture/whisper")
    #expect(abs(latest.windowDuration - 2.6) < 0.001)
    #expect(latest.inferenceLatency > 0)
    let timestamps = await transcriptRecorder.timestamps
    let expectedTimestamps = [20.0, 21.5, 22.6, 23.7]
    #expect(timestamps.count == expectedTimestamps.count)
    #expect(
        zip(timestamps, expectedTimestamps).allSatisfy { actual, expected in
            abs(actual - expected) < 0.001
        }
    )
    await coordinator.stop()
}

@Test
func coordinatorStopSuppressesCallbacksFromPreviousSession() async throws {
    let engine = BlockingWhisperEngine()
    let recorder = TranscriptRecorder()
    let coordinator = WhisperTranscriptionCoordinator(engine: engine)

    try await coordinator.start(
        modelID: "fixture/whisper",
        language: "English",
        onTranscript: { transcript in
            await recorder.append(transcript)
        }
    )
    await coordinator.ingest(testAudioChunk(duration: 3, timestamp: 30))

    try await eventually {
        await engine.hasPendingInference
    }

    await coordinator.stop()
    await engine.completePendingInference(text: "stale transcript")
    try await Task.sleep(for: .milliseconds(20))

    #expect(await recorder.count == 0)
}

@Test
func coordinatorPreservesPendingAudioWhenInferenceFallsBehind() async throws {
    let engine = BlockingWhisperEngine()
    let coordinator = WhisperTranscriptionCoordinator(
        engine: engine,
        configuration: .init(
            preferredWindowDuration: 1,
            maximumWindowDuration: 3,
            silenceFlushDelay: 10,
            overlapDuration: 0.2
        )
    )

    try await coordinator.start(
        modelID: "fixture/whisper",
        language: "English",
        onTranscript: { _ in }
    )
    await coordinator.ingest(testAudioChunk(duration: 1, timestamp: 0))
    try await eventually {
        await engine.hasPendingInference
    }

    await coordinator.ingest(testAudioChunk(duration: 4, timestamp: 1))
    await engine.completePendingInference(text: "first")
    try await eventually {
        await engine.inferenceWindows.count >= 2
    }

    let windows = await engine.inferenceWindows
    #expect(abs(windows[1].duration - 2.6) < 0.001)
    #expect(abs(windows[1].timestamp - 0.8) < 0.001)

    await engine.completePendingInference(text: "second")
    try await eventually {
        await engine.inferenceWindows.count >= 3
    }

    let preservedWindows = await engine.inferenceWindows
    guard preservedWindows.count >= 3 else {
        await coordinator.stop()
        await engine.completePendingInference(text: "cancelled")
        return
    }
    let secondWindowEnd = preservedWindows[1].timestamp + preservedWindows[1].duration
    #expect(preservedWindows[2].timestamp <= secondWindowEnd)
    #expect(abs(preservedWindows[2].timestamp - 3.2) < 0.001)

    await coordinator.stop()
    await engine.completePendingInference(text: "cancelled")
}

@Test
func silenceAfterHardLimitDoesNotRetranscribeOverlapOnly() async throws {
    let engine = SequencingWhisperEngine()
    let diagnosticsRecorder = DiagnosticsRecorder()
    let coordinator = WhisperTranscriptionCoordinator(
        engine: engine,
        configuration: .init(silenceFlushDelay: 0.02)
    )

    try await coordinator.start(
        modelID: "fixture/whisper",
        language: "English",
        onTranscript: { _ in },
        onDiagnostics: { diagnostics in
            await diagnosticsRecorder.append(diagnostics)
        }
    )
    await coordinator.ingest(testAudioChunk(duration: 2.6, timestamp: 40))

    try await eventually {
        await diagnosticsRecorder.latest.processedWindowCount == 2
    }
    try await Task.sleep(for: .milliseconds(40))

    #expect(await diagnosticsRecorder.latest.processedWindowCount == 2)
    await coordinator.stop()
}

private actor SequencingWhisperEngine: WhisperEngineProtocol {
    private let inferenceDelay: Duration
    private var inferenceCount = 0
    private var concurrentInferenceCount = 0
    private(set) var maximumConcurrentInferenceCount = 0
    private(set) var inferenceWindows: [AudioChunk] = []

    init(inferenceDelay: Duration = .zero) {
        self.inferenceDelay = inferenceDelay
    }

    func loadModel(named modelName: String) async throws {}

    func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript? {
        inferenceWindows.append(chunk)
        concurrentInferenceCount += 1
        maximumConcurrentInferenceCount = max(
            maximumConcurrentInferenceCount,
            concurrentInferenceCount
        )
        if inferenceDelay > .zero {
            try await Task.sleep(for: inferenceDelay)
        }
        concurrentInferenceCount -= 1
        inferenceCount += 1
        return Transcript(text: "window \(inferenceCount)", timestamp: chunk.timestamp)
    }
}

private actor BlockingWhisperEngine: WhisperEngineProtocol {
    private var continuation: CheckedContinuation<Transcript?, Never>?
    private var pendingTimestamp: TimeInterval = 0
    private(set) var inferenceWindows: [AudioChunk] = []

    var hasPendingInference: Bool {
        continuation != nil
    }

    func loadModel(named modelName: String) async throws {}

    func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript? {
        pendingTimestamp = chunk.timestamp
        inferenceWindows.append(chunk)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func completePendingInference(text: String) {
        continuation?.resume(returning: Transcript(text: text, timestamp: pendingTimestamp))
        continuation = nil
    }
}

private actor TranscriptRecorder {
    private var values: [Transcript] = []

    var count: Int { values.count }
    var first: Transcript? { values.first }
    var timestamps: [TimeInterval] { values.map(\.timestamp) }

    func append(_ transcript: Transcript) {
        values.append(transcript)
    }
}

private actor DiagnosticsRecorder {
    private var values: [WhisperDiagnostics] = []

    var latest: WhisperDiagnostics {
        values.last ?? WhisperDiagnostics()
    }

    func append(_ diagnostics: WhisperDiagnostics) {
        values.append(diagnostics)
    }
}

private func eventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition was not met before timeout")
}

private func testAudioChunk(
    duration: TimeInterval,
    timestamp: TimeInterval,
    sampleValue: Float = 0.05,
    isSpeechLike: Bool = true
) -> AudioChunk {
    AudioChunk(
        samples: Array(repeating: sampleValue, count: Int((duration * 16_000).rounded())),
        sampleRate: 16_000,
        channelCount: 1,
        timestamp: timestamp,
        duration: duration,
        isSpeechLike: isSpeechLike
    )
}
