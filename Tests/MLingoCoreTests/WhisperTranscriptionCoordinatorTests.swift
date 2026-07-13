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
    await coordinator.ingest(testAudioChunk(duration: 3, timestamp: 23))

    try await eventually {
        await diagnosticsRecorder.latest.processedWindowCount == 2
    }

    #expect(await engine.maximumConcurrentInferenceCount == 1)
    let latest = await diagnosticsRecorder.latest
    #expect(latest.modelState == .ready)
    #expect(latest.modelID == "fixture/whisper")
    #expect(latest.windowDuration == 3)
    #expect(latest.inferenceLatency > 0)
    #expect(await transcriptRecorder.timestamps == [20, 23])
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
    await coordinator.ingest(testAudioChunk(duration: 3, timestamp: 40))

    try await eventually {
        await diagnosticsRecorder.latest.processedWindowCount == 1
    }
    try await Task.sleep(for: .milliseconds(40))

    #expect(await diagnosticsRecorder.latest.processedWindowCount == 1)
    await coordinator.stop()
}

private actor SequencingWhisperEngine: WhisperEngineProtocol {
    private let inferenceDelay: Duration
    private var inferenceCount = 0
    private var concurrentInferenceCount = 0
    private(set) var maximumConcurrentInferenceCount = 0

    init(inferenceDelay: Duration = .zero) {
        self.inferenceDelay = inferenceDelay
    }

    func loadModel(named modelName: String) async throws {}

    func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript? {
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

    var hasPendingInference: Bool {
        continuation != nil
    }

    func loadModel(named modelName: String) async throws {}

    func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript? {
        pendingTimestamp = chunk.timestamp
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
    timestamp: TimeInterval
) -> AudioChunk {
    AudioChunk(
        samples: Array(repeating: 0.05, count: Int((duration * 16_000).rounded())),
        sampleRate: 16_000,
        channelCount: 1,
        timestamp: timestamp,
        duration: duration
    )
}
