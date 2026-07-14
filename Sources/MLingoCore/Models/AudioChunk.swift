import Foundation

public struct AudioChunk: Equatable, Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let channelCount: Int
    public let timestamp: TimeInterval
    public let duration: TimeInterval
    public let isSpeechLike: Bool

    public init(
        samples: [Float],
        sampleRate: Double,
        channelCount: Int,
        timestamp: TimeInterval,
        duration: TimeInterval,
        isSpeechLike: Bool = true
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.timestamp = timestamp
        self.duration = duration
        self.isSpeechLike = isSpeechLike
    }
}
