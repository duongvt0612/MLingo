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
func coordinatorUsesSampleDurationWhenMetadataDurationIsZero() async throws {
    let engine = SequencingWhisperEngine()
    let recorder = TranscriptRecorder()
    let coordinator = WhisperTranscriptionCoordinator(
        engine: engine,
        configuration: .init(silenceFlushDelay: 0.02)
    )

    try await coordinator.start(
        modelID: "fixture/whisper",
        language: "English",
        onTranscript: { await recorder.append($0) }
    )
    await coordinator.ingest(
        testAudioChunk(duration: 0.45, timestamp: 0, metadataDuration: 0)
    )

    try await eventually { await recorder.count == 1 }
    #expect(await engine.inferenceWindows.first?.samples.count == 7_200)
    await coordinator.stop()
}

@Test
func coordinatorBoundsZeroMetadataPreRollUsingSampleDuration() async throws {
    let engine = SequencingWhisperEngine()
    let coordinator = WhisperTranscriptionCoordinator(
        engine: engine,
        configuration: .init(
            minimumSpeechDuration: 0.1,
            preferredWindowDuration: 1,
            maximumWindowDuration: 2,
            silenceFlushDelay: 0.02,
            overlapDuration: 0.2
        )
    )

    try await coordinator.start(
        modelID: "fixture/whisper",
        language: "English",
        onTranscript: { _ in }
    )
    for index in 0..<5 {
        await coordinator.ingest(
            testAudioChunk(
                duration: 0.1,
                timestamp: Double(index) * 0.1,
                sampleValue: 0.001,
                isSpeechLike: false,
                metadataDuration: 0
            )
        )
    }
    await coordinator.ingest(
        testAudioChunk(duration: 0.2, timestamp: 0.5, metadataDuration: 0)
    )

    try await eventually { await engine.inferenceWindows.count == 1 }
    let window = try #require(await engine.inferenceWindows.first)
    #expect(abs(window.timestamp - 0.3) < 0.001)
    #expect(abs(window.duration - 0.4) < 0.001)
    await coordinator.stop()
}

@Test
func coordinatorRejectsAudioUntilModelFinishesLoading() async throws {
    let engine = BlockingLoadWhisperEngine()
    let coordinator = WhisperTranscriptionCoordinator(
        engine: engine,
        configuration: .init(silenceFlushDelay: 0.02)
    )
    let startTask = Task {
        try await coordinator.start(
            modelID: "fixture/whisper",
            language: "English",
            onTranscript: { _ in }
        )
    }

    try await eventually { await engine.hasPendingLoad }
    await coordinator.ingest(testAudioChunk(duration: 0.45, timestamp: 0))
    await engine.completeLoad()
    try await startTask.value
    try await Task.sleep(for: .milliseconds(30))
    #expect(await engine.inferenceWindows.isEmpty)

    await coordinator.ingest(testAudioChunk(duration: 0.45, timestamp: 1))
    try await eventually { await engine.inferenceWindows.count == 1 }
    #expect(await engine.inferenceWindows.first?.timestamp == 1)
    await coordinator.stop()
}

@Test
func coordinatorRevalidatesSessionAfterLoadingDiagnosticsCallback() async {
    let engine = CountingLoadWhisperEngine()
    let coordinator = WhisperTranscriptionCoordinator(engine: engine)

    await #expect(throws: CancellationError.self) {
        try await coordinator.start(
            modelID: "fixture/whisper",
            language: "English",
            onTranscript: { _ in },
            onDiagnostics: { diagnostics in
                if diagnostics.modelState == .loading {
                    await coordinator.stop()
                }
            }
        )
    }

    #expect(await engine.loadCount == 0)
}

@Test
func coordinatorStopWaitsForOwnedModelLoadingTask() async throws {
    let engine = BlockingLoadWhisperEngine()
    let coordinator = WhisperTranscriptionCoordinator(engine: engine)
    let stopped = AsyncFlag()
    let startTask = Task {
        try await coordinator.start(
            modelID: "fixture/whisper",
            language: "English",
            onTranscript: { _ in }
        )
    }

    try await eventually { await engine.hasPendingLoad }
    let stopTask = Task {
        await coordinator.stop()
        await stopped.set()
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await stopped.value))

    await engine.completeLoad()
    await stopTask.value
    do {
        try await startTask.value
        Issue.record("Expected the cancelled model load to abort startup")
    } catch is CancellationError {
        // Expected.
    } catch {
        Issue.record("Expected CancellationError, received \(error)")
    }
}

@Test
func coordinatorDoesNotAcceptAudioAfterModelLoadFailure() async throws {
    let engine = FailingLoadWhisperEngine()
    let coordinator = WhisperTranscriptionCoordinator(engine: engine)

    do {
        try await coordinator.start(
            modelID: "fixture/whisper",
            language: "English",
            onTranscript: { _ in }
        )
        Issue.record("Expected model loading to fail")
    } catch {
        // Expected.
    }

    await coordinator.ingest(testAudioChunk(duration: 1, timestamp: 0))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await engine.inferenceCount == 0)
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
        await diagnosticsRecorder.latest.processedWindowCount == 1
    }
    await coordinator.ingest(testAudioChunk(duration: 3, timestamp: 23))

    try await eventually {
        await diagnosticsRecorder.latest.processedWindowCount == 2
    }

    #expect(await engine.maximumConcurrentInferenceCount == 1)
    let latest = await diagnosticsRecorder.latest
    #expect(latest.modelState == .ready)
    #expect(latest.modelID == "fixture/whisper")
    #expect(abs(latest.windowDuration - 3.0) < 0.001)
    #expect(latest.inferenceLatency > 0)
    let timestamps = await transcriptRecorder.timestamps
    let expectedTimestamps = [20.0, 23.0]
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

    let stopTask = Task { await coordinator.stop() }
    try await eventually {
        await engine.hasCancelledInference
    }
    await engine.completePendingInference(text: "stale transcript")
    await stopTask.value
    try await Task.sleep(for: .milliseconds(20))

    #expect(await recorder.count == 0)
}

@Test
func coordinatorStopWaitsForOwnedInferenceTask() async throws {
    let engine = BlockingWhisperEngine()
    let coordinator = WhisperTranscriptionCoordinator(engine: engine)
    let stopped = AsyncFlag()

    try await coordinator.start(
        modelID: "fixture/whisper",
        language: "English",
        onTranscript: { _ in }
    )
    await coordinator.ingest(testAudioChunk(duration: 3, timestamp: 0))
    try await eventually { await engine.hasPendingInference }

    let stopTask = Task {
        await coordinator.stop()
        await stopped.set()
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(!(await stopped.value))

    await engine.completePendingInference(text: "cancelled")
    await stopTask.value
    #expect(await stopped.value)
}

@Test
func coordinatorBoundsPendingWindowBacklog() async throws {
    let engine = BlockingWhisperEngine()
    let diagnosticsRecorder = DiagnosticsRecorder()
    let coordinator = WhisperTranscriptionCoordinator(
        engine: engine,
        configuration: .init(
            preferredWindowDuration: 3,
            maximumWindowDuration: 3,
            silenceFlushDelay: 10,
            overlapDuration: 0
        ),
        maximumPendingWindowDuration: 3
    )

    try await coordinator.start(
        modelID: "fixture/whisper",
        language: "English",
        onTranscript: { _ in },
        onDiagnostics: { await diagnosticsRecorder.append($0) }
    )
    await coordinator.ingest(testAudioChunk(duration: 3, timestamp: 0))
    try await eventually { await engine.hasPendingInference }
    await coordinator.ingest(testAudioChunk(duration: 9, timestamp: 3))

    await engine.completePendingInference(text: "first")
    try await eventually { await engine.inferenceWindows.count == 2 }

    let windows = await engine.inferenceWindows
    #expect(windows[1].timestamp == 9)
    #expect(await diagnosticsRecorder.latest.droppedBacklogWindowCount == 2)

    let stopTask = Task { await coordinator.stop() }
    await engine.completePendingInference(text: "cancelled")
    await stopTask.value
}

@Test
func coordinatorRejectsUnrepresentableCoalescingGap() {
    let older = testAudioChunk(duration: 1, timestamp: 0)
    let newer = testAudioChunk(duration: 1, timestamp: .greatestFiniteMagnitude)

    #expect(
        WhisperTranscriptionCoordinator.coalesceWithoutDropping(
            older,
            with: newer,
            maximumDuration: 3
        ) == nil
    )
}

@Test
func coordinatorDoesNotMutateReplacementSessionAfterTranscriptCallback() async throws {
    let engine = SequencingWhisperEngine()
    let replacementDiagnostics = DiagnosticsRecorder()
    let coordinator = WhisperTranscriptionCoordinator(engine: engine)

    try await coordinator.start(
        modelID: "first-model",
        language: "English",
        onTranscript: { _ in
            try? await coordinator.start(
                modelID: "replacement-model",
                language: "English",
                onTranscript: { _ in },
                onDiagnostics: { await replacementDiagnostics.append($0) }
            )
        }
    )
    await coordinator.ingest(testAudioChunk(duration: 3, timestamp: 0))

    try await eventually {
        let latest = await replacementDiagnostics.latest
        return latest.modelID == "replacement-model" && latest.modelState == .ready
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await replacementDiagnostics.count == 2)
    await coordinator.stop()
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
    await coordinator.ingest(testAudioChunk(duration: 3, timestamp: 0))
    try await eventually {
        await engine.hasPendingInference
    }

    await coordinator.ingest(testAudioChunk(duration: 6, timestamp: 3))
    await engine.completePendingInference(text: "first")
    try await eventually {
        await engine.inferenceWindows.count >= 2
    }

    let windows = await engine.inferenceWindows
    #expect(abs(windows[1].duration - 3.0) < 0.001)
    #expect(abs(windows[1].timestamp - 2.8) < 0.001)

    await engine.completePendingInference(text: "second")
    try await eventually {
        await engine.inferenceWindows.count >= 3
    }

    let preservedWindows = await engine.inferenceWindows
    guard preservedWindows.count >= 3 else {
        let stopTask = Task { await coordinator.stop() }
        await engine.completePendingInference(text: "cancelled")
        await stopTask.value
        return
    }
    let secondWindowEnd = preservedWindows[1].timestamp + preservedWindows[1].duration
    #expect(preservedWindows[2].timestamp < secondWindowEnd)
    #expect(abs(preservedWindows[2].timestamp - 5.6) < 0.001)

    let stopTask = Task { await coordinator.stop() }
    await engine.completePendingInference(text: "cancelled")
    await stopTask.value
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

@Test
func coordinatorStitchesFuzzyOverlapBeforeEmittingTranscript() async throws {
    let engine = ScriptedWhisperEngine(texts: [
        "We need a very reliable transcript",
        "a really reliable transcript before translation starts",
    ])
    let recorder = TranscriptRecorder()
    let coordinator = WhisperTranscriptionCoordinator(
        engine: engine,
        configuration: .init(
            minimumSpeechDuration: 0.1,
            preferredWindowDuration: 1,
            maximumWindowDuration: 1,
            silenceFlushDelay: 10,
            overlapDuration: 0.4
        )
    )

    try await coordinator.start(
        modelID: "fixture/whisper",
        language: "English",
        onTranscript: { transcript in
            await recorder.append(transcript)
        }
    )
    await coordinator.ingest(testAudioChunk(duration: 1, timestamp: 0))
    try await eventually { await recorder.count == 1 }
    await coordinator.ingest(testAudioChunk(duration: 0.6, timestamp: 1))
    try await eventually { await recorder.count == 2 }

    #expect(await recorder.texts == [
        "We need a very reliable transcript",
        "before translation starts",
    ])
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
    private let cancellation = AsyncFlag()
    private(set) var inferenceWindows: [AudioChunk] = []

    var hasPendingInference: Bool {
        continuation != nil
    }

    var hasCancelledInference: Bool {
        get async { await cancellation.value }
    }

    func loadModel(named modelName: String) async throws {}

    func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript? {
        pendingTimestamp = chunk.timestamp
        inferenceWindows.append(chunk)
        let cancellation = cancellation
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await cancellation.set() }
        }
    }

    func completePendingInference(text: String) {
        continuation?.resume(returning: Transcript(text: text, timestamp: pendingTimestamp))
        continuation = nil
    }
}

private actor ScriptedWhisperEngine: WhisperEngineProtocol {
    private var texts: [String]

    init(texts: [String]) {
        self.texts = texts
    }

    func loadModel(named modelName: String) async throws {}

    func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript? {
        guard !texts.isEmpty else { return nil }
        return Transcript(text: texts.removeFirst(), timestamp: chunk.timestamp)
    }
}

private actor BlockingLoadWhisperEngine: WhisperEngineProtocol {
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private(set) var inferenceWindows: [AudioChunk] = []

    var hasPendingLoad: Bool { loadContinuation != nil }

    func loadModel(named modelName: String) async throws {
        await withCheckedContinuation { continuation in
            loadContinuation = continuation
        }
    }

    func completeLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript? {
        inferenceWindows.append(chunk)
        return Transcript(text: "loaded", timestamp: chunk.timestamp)
    }
}

private actor CountingLoadWhisperEngine: WhisperEngineProtocol {
    private(set) var loadCount = 0

    func loadModel(named modelName: String) async throws { loadCount += 1 }
    func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript? { nil }
}

private actor FailingLoadWhisperEngine: WhisperEngineProtocol {
    private(set) var inferenceCount = 0

    func loadModel(named modelName: String) async throws {
        throw MLingoError.whisperModelLoadFailed("fixture failure")
    }

    func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript? {
        inferenceCount += 1
        return nil
    }
}

private actor TranscriptRecorder {
    private var values: [Transcript] = []

    var count: Int { values.count }
    var first: Transcript? { values.first }
    var timestamps: [TimeInterval] { values.map(\.timestamp) }
    var texts: [String] { values.map(\.text) }

    func append(_ transcript: Transcript) {
        values.append(transcript)
    }
}

private actor DiagnosticsRecorder {
    private var values: [WhisperDiagnostics] = []

    var count: Int { values.count }

    var latest: WhisperDiagnostics {
        values.last ?? WhisperDiagnostics()
    }

    func append(_ diagnostics: WhisperDiagnostics) {
        values.append(diagnostics)
    }
}

private actor AsyncFlag {
    private(set) var value = false
    func set() { value = true }
}

private enum EventuallyError: Error {
    case timedOut
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
    throw EventuallyError.timedOut
}

private func testAudioChunk(
    duration: TimeInterval,
    timestamp: TimeInterval,
    sampleValue: Float = 0.05,
    isSpeechLike: Bool = true,
    metadataDuration: TimeInterval? = nil
) -> AudioChunk {
    AudioChunk(
        samples: Array(repeating: sampleValue, count: Int((duration * 16_000).rounded())),
        sampleRate: 16_000,
        channelCount: 1,
        timestamp: timestamp,
        duration: metadataDuration ?? duration,
        isSpeechLike: isSpeechLike
    )
}
