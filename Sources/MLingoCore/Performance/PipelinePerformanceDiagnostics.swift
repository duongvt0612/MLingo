import Foundation

public struct LatencyStatistics: Equatable, Sendable {
    public let latest: TimeInterval?
    public let p50: TimeInterval?
    public let p95: TimeInterval?
    public let sampleCount: Int

    public init(
        latest: TimeInterval? = nil,
        p50: TimeInterval? = nil,
        p95: TimeInterval? = nil,
        sampleCount: Int = 0
    ) {
        self.latest = latest
        self.p50 = p50
        self.p95 = p95
        self.sampleCount = sampleCount
    }
}

public struct PipelinePerformanceDiagnostics: Equatable, Sendable {
    public let audioToWhisperLatency: LatencyStatistics
    public let whisperDecodeLatency: LatencyStatistics
    public let translationQueueLatency: LatencyStatistics
    public let translationRequestLatency: LatencyStatistics
    public let overlayRenderLatency: LatencyStatistics
    public let totalLatency: LatencyStatistics
    public let sessionDuration: TimeInterval
    public let whisperPendingAudioDuration: TimeInterval
    public let translationQueueDepth: Int
    public let peakTranslationQueueDepth: Int
    public let droppedWhisperWindowCount: Int
    public let skippedTranslationCount: Int
    public let duplicateTranslationCount: Int
    public let cpuUsagePercent: Double?
    public let residentMemoryBytes: UInt64?

    public init(
        audioToWhisperLatency: LatencyStatistics = .init(),
        whisperDecodeLatency: LatencyStatistics = .init(),
        translationQueueLatency: LatencyStatistics = .init(),
        translationRequestLatency: LatencyStatistics = .init(),
        overlayRenderLatency: LatencyStatistics = .init(),
        totalLatency: LatencyStatistics = .init(),
        sessionDuration: TimeInterval = 0,
        whisperPendingAudioDuration: TimeInterval = 0,
        translationQueueDepth: Int = 0,
        peakTranslationQueueDepth: Int = 0,
        droppedWhisperWindowCount: Int = 0,
        skippedTranslationCount: Int = 0,
        duplicateTranslationCount: Int = 0,
        cpuUsagePercent: Double? = nil,
        residentMemoryBytes: UInt64? = nil
    ) {
        self.audioToWhisperLatency = audioToWhisperLatency
        self.whisperDecodeLatency = whisperDecodeLatency
        self.translationQueueLatency = translationQueueLatency
        self.translationRequestLatency = translationRequestLatency
        self.overlayRenderLatency = overlayRenderLatency
        self.totalLatency = totalLatency
        self.sessionDuration = sessionDuration
        self.whisperPendingAudioDuration = whisperPendingAudioDuration
        self.translationQueueDepth = translationQueueDepth
        self.peakTranslationQueueDepth = peakTranslationQueueDepth
        self.droppedWhisperWindowCount = droppedWhisperWindowCount
        self.skippedTranslationCount = skippedTranslationCount
        self.duplicateTranslationCount = duplicateTranslationCount
        self.cpuUsagePercent = cpuUsagePercent
        self.residentMemoryBytes = residentMemoryBytes
    }
}
