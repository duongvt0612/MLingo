@preconcurrency import AVFoundation
import Foundation

enum MonoFloat32Resampling {
    static func makeConverter(
        sourceSampleRate: Double,
        targetSampleRate: Double
    ) -> AVAudioConverter? {
        guard sourceSampleRate > 0, targetSampleRate > 0,
              let sourceFormat = makeFormat(sampleRate: sourceSampleRate),
              let targetFormat = makeFormat(sampleRate: targetSampleRate)
        else {
            return nil
        }
        return AVAudioConverter(from: sourceFormat, to: targetFormat)
    }

    static func convert(
        _ samples: [Float],
        using converter: AVAudioConverter,
        outputCapacityPadding: AVAudioFrameCount,
        exhaustedInputStatus: AVAudioConverterInputStatus,
        logErrors: Bool
    ) -> [Float]? {
        guard !samples.isEmpty,
              let sourceBuffer = AVAudioPCMBuffer(
                  pcmFormat: converter.inputFormat,
                  frameCapacity: AVAudioFrameCount(samples.count)
              )
        else {
            return nil
        }

        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        guard let sourceChannel = sourceBuffer.floatChannelData?[0] else { return nil }
        sourceChannel.update(from: samples, count: samples.count)

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let outputCapacity = max(
            AVAudioFrameCount(ceil(Double(samples.count) * ratio)) + outputCapacityPadding,
            1
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputCapacity
        ) else {
            return nil
        }

        let inputProvider = MonoFloat32ConverterInputProvider(
            buffer: sourceBuffer,
            exhaustedInputStatus: exhaustedInputStatus
        )
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            inputProvider.next(status: status)
        }
        guard status != .error,
              conversionError == nil,
              let outputChannel = outputBuffer.floatChannelData?[0]
        else {
            if logErrors, let conversionError {
                MLingoLogger.audio.error(
                    "Audio resampling failed: \(conversionError.localizedDescription, privacy: .public)"
                )
            }
            return nil
        }

        return Array(
            UnsafeBufferPointer(
                start: outputChannel,
                count: Int(outputBuffer.frameLength)
            )
        )
    }

    private static func makeFormat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
    }
}

private final class MonoFloat32ConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let exhaustedInputStatus: AVAudioConverterInputStatus
    private var didProvideInput = false

    init(
        buffer: AVAudioPCMBuffer,
        exhaustedInputStatus: AVAudioConverterInputStatus
    ) {
        self.buffer = buffer
        self.exhaustedInputStatus = exhaustedInputStatus
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !didProvideInput else {
            status.pointee = exhaustedInputStatus
            return nil
        }
        didProvideInput = true
        status.pointee = .haveData
        return buffer
    }
}
