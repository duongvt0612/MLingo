import Foundation

typealias PerformanceInstant = ContinuousClock.Instant
typealias PerformanceNow = @Sendable () -> PerformanceInstant

enum PerformanceStage: CaseIterable, Sendable {
    case audioToWhisper
    case whisperDecode
    case translationQueue
    case translationRequest
    case overlayRender
    case total
}

struct WhisperPerformanceEvent: Sendable {
    let traceID: UUID
    let transcriptID: UUID?
    let speechEnd: PerformanceInstant?
    let decodeStarted: PerformanceInstant
    let decodeEnded: PerformanceInstant
    let pendingAudioDuration: TimeInterval
    let droppedBacklogWindowCount: Int
}

enum WhisperPerformanceUpdate: Sendable {
    case completed(WhisperPerformanceEvent)
    case queue(pendingAudioDuration: TimeInterval, droppedBacklogWindowCount: Int)
}

@MainActor
final class PipelinePerformanceTracker {
    private struct Trace: Sendable {
        let traceID: UUID
        let speechEnd: PerformanceInstant?
        var translationQueued: PerformanceInstant?
        var translationStarted: PerformanceInstant?
    }

    private let capacity: Int
    private let startedAt: PerformanceInstant
    private let now: PerformanceNow
    private var samples: [PerformanceStage: [TimeInterval]] = [:]
    private var traces: [UUID: Trace] = [:]
    private var whisperPendingAudioDuration: TimeInterval = 0
    private var translationQueueDepth = 0
    private var peakTranslationQueueDepth = 0
    private var droppedWhisperWindowCount = 0
    private var skippedTranslationCount = 0
    private var duplicateTranslationCount = 0
    private var cpuUsagePercent: Double?
    private var residentMemoryBytes: UInt64?

    init(capacity: Int = 4_096, now: @escaping PerformanceNow = { .now }) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.now = now
        startedAt = now()
    }

    func recordWhisper(_ event: WhisperPerformanceEvent) {
        whisperPendingAudioDuration = max(0, event.pendingAudioDuration)
        droppedWhisperWindowCount = max(
            droppedWhisperWindowCount,
            event.droppedBacklogWindowCount
        )
        appendDuration(from: event.speechEnd, to: event.decodeStarted, stage: .audioToWhisper)
        appendDuration(
            from: event.decodeStarted,
            to: event.decodeEnded,
            stage: .whisperDecode
        )

        guard let transcriptID = event.transcriptID else { return }
        traces[transcriptID] = Trace(
            traceID: event.traceID,
            speechEnd: event.speechEnd
        )
    }

    func updateWhisperQueue(pendingDuration: TimeInterval, droppedCount: Int) {
        whisperPendingAudioDuration = max(0, pendingDuration)
        droppedWhisperWindowCount = max(droppedWhisperWindowCount, droppedCount)
    }

    func recordTranslationQueued(transcriptID: UUID, at instant: PerformanceInstant) {
        guard var trace = traces[transcriptID] else { return }
        trace.translationQueued = instant
        traces[transcriptID] = trace
    }

    func traceID(for transcriptID: UUID) -> UUID? {
        traces[transcriptID]?.traceID
    }

    func recordTranslationStarted(transcriptID: UUID, at instant: PerformanceInstant) {
        guard var trace = traces[transcriptID] else { return }
        trace.translationStarted = instant
        traces[transcriptID] = trace
        appendDuration(from: trace.translationQueued, to: instant, stage: .translationQueue)
    }

    func recordTranslationFinished(transcriptID: UUID, at instant: PerformanceInstant) {
        guard let trace = traces[transcriptID] else { return }
        appendDuration(from: trace.translationStarted, to: instant, stage: .translationRequest)
    }

    func recordOverlayRendered(
        transcriptID: UUID,
        startedAt: PerformanceInstant,
        endedAt: PerformanceInstant
    ) {
        guard let trace = traces.removeValue(forKey: transcriptID) else { return }
        appendDuration(from: startedAt, to: endedAt, stage: .overlayRender)
        appendDuration(from: trace.speechEnd, to: endedAt, stage: .total)
    }

    func discardTrace(transcriptID: UUID, duplicate: Bool = false, skipped: Bool = false) {
        traces[transcriptID] = nil
        if duplicate {
            duplicateTranslationCount += 1
        }
        if skipped {
            skippedTranslationCount += 1
        }
    }

    func updateTranslationQueue(depth: Int) {
        translationQueueDepth = max(0, depth)
        peakTranslationQueueDepth = max(peakTranslationQueueDepth, translationQueueDepth)
    }

    func updateResources(_ sample: ProcessResourceSample?) {
        cpuUsagePercent = sample?.cpuUsagePercent
        residentMemoryBytes = sample?.residentMemoryBytes
    }

    func snapshot() -> PipelinePerformanceDiagnostics {
        PipelinePerformanceDiagnostics(
            audioToWhisperLatency: statistics(for: .audioToWhisper),
            whisperDecodeLatency: statistics(for: .whisperDecode),
            translationQueueLatency: statistics(for: .translationQueue),
            translationRequestLatency: statistics(for: .translationRequest),
            overlayRenderLatency: statistics(for: .overlayRender),
            totalLatency: statistics(for: .total),
            sessionDuration: max(0, startedAt.duration(to: now()).timeInterval),
            whisperPendingAudioDuration: whisperPendingAudioDuration,
            translationQueueDepth: translationQueueDepth,
            peakTranslationQueueDepth: peakTranslationQueueDepth,
            droppedWhisperWindowCount: droppedWhisperWindowCount,
            skippedTranslationCount: skippedTranslationCount,
            duplicateTranslationCount: duplicateTranslationCount,
            cpuUsagePercent: cpuUsagePercent,
            residentMemoryBytes: residentMemoryBytes
        )
    }

    private func appendDuration(
        from start: PerformanceInstant?,
        to end: PerformanceInstant,
        stage: PerformanceStage
    ) {
        guard let start else { return }
        let duration = start.duration(to: end).timeInterval
        guard duration.isFinite, duration >= 0 else { return }
        var stageSamples = samples[stage, default: []]
        stageSamples.append(duration)
        if stageSamples.count > capacity {
            stageSamples.removeFirst(stageSamples.count - capacity)
        }
        samples[stage] = stageSamples
    }

    private func statistics(for stage: PerformanceStage) -> LatencyStatistics {
        guard let stageSamples = samples[stage], !stageSamples.isEmpty else {
            return LatencyStatistics()
        }
        let sorted = stageSamples.sorted()
        return LatencyStatistics(
            latest: stageSamples.last,
            p50: Self.nearestRank(0.50, in: sorted),
            p95: Self.nearestRank(0.95, in: sorted),
            sampleCount: stageSamples.count
        )
    }

    static func nearestRank(_ percentile: Double, in sortedSamples: [TimeInterval]) -> TimeInterval? {
        guard !sortedSamples.isEmpty else { return nil }
        let clamped = min(max(percentile, 0), 1)
        let rank = max(1, Int(ceil(clamped * Double(sortedSamples.count))))
        return sortedSamples[min(rank - 1, sortedSamples.count - 1)]
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
