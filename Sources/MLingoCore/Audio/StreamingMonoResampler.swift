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
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceSampleRate,
                channels: 1,
                interleaved: false
            ),
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else {
            return nil
        }

        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        guard let sourceChannel = sourceBuffer.floatChannelData?[0] else { return nil }
        sourceChannel.update(from: samples, count: samples.count)

        let outputCapacity = max(
            AVAudioFrameCount(ceil(Double(samples.count) * targetSampleRate / sourceSampleRate)) + 64,
            1
        )
        guard
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: outputCapacity
            )
        else {
            return nil
        }

        let inputProvider = StreamingResamplerInputProvider(buffer: sourceBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            inputProvider.next(status: inputStatus)
        }
        guard
            status != .error,
            conversionError == nil,
            let outputChannel = outputBuffer.floatChannelData?[0]
        else {
            return nil
        }
        return Array(
            UnsafeBufferPointer(
                start: outputChannel,
                count: Int(outputBuffer.frameLength)
            )
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
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: newSourceSampleRate,
                channels: 1,
                interleaved: false
            ),
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        else {
            return nil
        }
        sourceSampleRate = newSourceSampleRate
        self.converter = converter
        return converter
    }
}

private final class StreamingResamplerInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !didProvideInput else {
            status.pointee = .noDataNow
            return nil
        }
        didProvideInput = true
        status.pointee = .haveData
        return buffer
    }
}
