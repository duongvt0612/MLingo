@preconcurrency import AVFoundation
import Foundation

final class StreamingMonoResampler {
    private let targetSampleRate: Double
    private var sourceSampleRate: Double = 0
    private var converter: AVAudioConverter?

    init(targetSampleRate: Double) {
        precondition(targetSampleRate > 0)
        self.targetSampleRate = targetSampleRate
    }

    func convert(_ samples: [Float], sourceSampleRate: Double) -> [Float]? {
        guard sourceSampleRate > 0, !samples.isEmpty else { return [] }
        guard sourceSampleRate != targetSampleRate else { return samples }
        guard let converter = converter(for: sourceSampleRate) else { return nil }
        return MonoFloat32Resampling.convert(
            samples,
            using: converter,
            outputCapacityPadding: 64,
            exhaustedInputStatus: .noDataNow,
            logErrors: false
        )
    }

    func reset() {
        sourceSampleRate = 0
        converter = nil
    }

    private func converter(for newSourceSampleRate: Double) -> AVAudioConverter? {
        if sourceSampleRate == newSourceSampleRate, let converter {
            return converter
        }
        guard let converter = MonoFloat32Resampling.makeConverter(
            sourceSampleRate: newSourceSampleRate,
            targetSampleRate: targetSampleRate
        ) else { return nil }
        sourceSampleRate = newSourceSampleRate
        self.converter = converter
        return converter
    }
}
