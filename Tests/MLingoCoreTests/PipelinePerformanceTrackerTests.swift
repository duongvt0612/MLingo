import Foundation
import Testing
@testable import MLingoCore

@MainActor
@Test
func performanceTrackerCorrelatesEveryCompletedStage() {
    let base = ContinuousClock.now
    let clock = TestPerformanceClock(instant: base)
    let tracker = PipelinePerformanceTracker(capacity: 16, now: clock.now)
    let transcriptID = UUID()

    tracker.recordWhisper(
        WhisperPerformanceEvent(
            traceID: UUID(),
            transcriptID: transcriptID,
            speechEnd: base,
            decodeStarted: base.advanced(by: .milliseconds(100)),
            decodeEnded: base.advanced(by: .milliseconds(300)),
            pendingAudioDuration: 1.25,
            droppedBacklogWindowCount: 2
        )
    )
    tracker.recordTranslationQueued(
        transcriptID: transcriptID,
        at: base.advanced(by: .milliseconds(350))
    )
    tracker.recordTranslationStarted(
        transcriptID: transcriptID,
        at: base.advanced(by: .milliseconds(400))
    )
    tracker.recordTranslationFinished(
        transcriptID: transcriptID,
        at: base.advanced(by: .milliseconds(650))
    )
    tracker.recordOverlayRendered(
        transcriptID: transcriptID,
        startedAt: base.advanced(by: .milliseconds(660)),
        endedAt: base.advanced(by: .milliseconds(680))
    )
    tracker.updateTranslationQueue(depth: 3)
    tracker.updateTranslationQueue(depth: 1)
    tracker.updateResources(
        ProcessResourceSample(cpuUsagePercent: 125, residentMemoryBytes: 64 * 1_024 * 1_024)
    )
    clock.advance(by: .seconds(2))

    let diagnostics = tracker.snapshot()

    #expect(diagnostics.audioToWhisperLatency.latest == 0.1)
    #expect(diagnostics.whisperDecodeLatency.latest == 0.2)
    #expect(diagnostics.translationQueueLatency.latest == 0.05)
    #expect(diagnostics.translationRequestLatency.latest == 0.25)
    #expect(diagnostics.overlayRenderLatency.latest == 0.02)
    #expect(diagnostics.totalLatency.latest == 0.68)
    #expect(diagnostics.totalLatency.sampleCount == 1)
    #expect(diagnostics.whisperPendingAudioDuration == 1.25)
    #expect(diagnostics.peakTranslationQueueDepth == 3)
    #expect(diagnostics.translationQueueDepth == 1)
    #expect(diagnostics.droppedWhisperWindowCount == 2)
    #expect(diagnostics.cpuUsagePercent == 125)
    #expect(diagnostics.residentMemoryBytes == 64 * 1_024 * 1_024)
    #expect(diagnostics.sessionDuration == 2)
}

@MainActor
@Test
func performanceTrackerUsesNearestRankAndBoundsSamples() {
    let base = ContinuousClock.now
    let tracker = PipelinePerformanceTracker(capacity: 3, now: { base })

    for index in 1...5 {
        let transcriptID = UUID()
        tracker.recordWhisper(
            WhisperPerformanceEvent(
                traceID: UUID(),
                transcriptID: transcriptID,
                speechEnd: base,
                decodeStarted: base,
                decodeEnded: base.advanced(by: .milliseconds(index)),
                pendingAudioDuration: 0,
                droppedBacklogWindowCount: 0
            )
        )
        tracker.discardTrace(transcriptID: transcriptID)
    }

    let statistics = tracker.snapshot().whisperDecodeLatency
    #expect(statistics.sampleCount == 3)
    #expect(statistics.latest == 0.005)
    #expect(statistics.p50 == 0.004)
    #expect(statistics.p95 == 0.005)
}

@MainActor
@Test
func incompleteTranslationTracesNeverEnterTotalLatency() {
    let base = ContinuousClock.now
    let tracker = PipelinePerformanceTracker(now: { base })
    let duplicateID = UUID()
    let skippedID = UUID()

    for transcriptID in [duplicateID, skippedID] {
        tracker.recordWhisper(
            WhisperPerformanceEvent(
                traceID: UUID(),
                transcriptID: transcriptID,
                speechEnd: base,
                decodeStarted: base.advanced(by: .milliseconds(10)),
                decodeEnded: base.advanced(by: .milliseconds(20)),
                pendingAudioDuration: 0,
                droppedBacklogWindowCount: 0
            )
        )
    }
    tracker.discardTrace(transcriptID: duplicateID, duplicate: true)
    tracker.discardTrace(transcriptID: skippedID, skipped: true)

    let diagnostics = tracker.snapshot()
    #expect(diagnostics.totalLatency.sampleCount == 0)
    #expect(diagnostics.duplicateTranslationCount == 1)
    #expect(diagnostics.skippedTranslationCount == 1)
}

@Test
func processMetricsSamplerReadsResidentMemoryWithoutCrashing() async throws {
    let sample = await DarwinProcessMetricsSampler().sample()
    let value = try #require(sample)
    #expect(value.residentMemoryBytes > 0)
}

private final class TestPerformanceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: PerformanceInstant

    init(instant: PerformanceInstant) {
        self.instant = instant
    }

    func now() -> PerformanceInstant {
        lock.withLock { instant }
    }

    func advance(by duration: Duration) {
        lock.withLock {
            instant = instant.advanced(by: duration)
        }
    }
}
