import Foundation

public struct AudioLevel: Equatable, Sendable {
    public let rms: Float
    public let peak: Float
    public let isSpeechLike: Bool

    public init(rms: Float, peak: Float, isSpeechLike: Bool) {
        self.rms = rms
        self.peak = peak
        self.isSpeechLike = isSpeechLike
    }
}

public enum AudioLevelAnalyzer {
    public static let defaultVADThreshold: Float = 0.015

    public static func analyze(
        samples: [Float],
        vadThreshold: Float = defaultVADThreshold
    ) -> AudioLevel {
        guard !samples.isEmpty else {
            return AudioLevel(rms: 0, peak: 0, isSpeechLike: false)
        }

        var sumOfSquares: Float = 0
        var peak: Float = 0

        for sample in samples {
            let magnitude = abs(sample)
            sumOfSquares += sample * sample
            peak = max(peak, magnitude)
        }

        let rms = sqrt(sumOfSquares / Float(samples.count))
        return AudioLevel(rms: rms, peak: peak, isSpeechLike: rms >= vadThreshold)
    }
}
