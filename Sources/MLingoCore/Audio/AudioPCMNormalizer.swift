@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

enum AudioPCMNormalizer {
    static let targetSampleRate: Double = 16_000
    static let targetChannelCount = 1

    static func normalize(
        bufferList: UnsafePointer<AudioBufferList>,
        streamDescription: AudioStreamBasicDescription
    ) -> [Float]? {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList)
        )
        let monoSamples = readMonoSamples(
            from: buffers,
            streamDescription: streamDescription
        )
        guard !monoSamples.isEmpty else { return [] }
        guard streamDescription.mSampleRate != targetSampleRate else {
            return monoSamples
        }
        return resampleMonoFloat32(
            monoSamples,
            sourceSampleRate: streamDescription.mSampleRate,
            targetSampleRate: targetSampleRate
        )
    }

    private static func readMonoSamples(
        from buffers: UnsafeMutableAudioBufferListPointer,
        streamDescription: AudioStreamBasicDescription
    ) -> [Float] {
        let flags = streamDescription.mFormatFlags
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (flags & kAudioFormatFlagIsNonInterleaved) != 0
        let channelCount = max(Int(streamDescription.mChannelsPerFrame), 1)
        let bitsPerChannel = Int(streamDescription.mBitsPerChannel)

        if isFloat, bitsPerChannel == 32 {
            return readFloat32MonoSamples(
                from: buffers,
                channelCount: channelCount,
                isNonInterleaved: isNonInterleaved
            )
        }

        if isSignedInteger, bitsPerChannel == 16 {
            return readInt16MonoSamples(
                from: buffers,
                channelCount: channelCount,
                isNonInterleaved: isNonInterleaved
            )
        }

        MLingoLogger.audio.error("Unsupported audio format: bits=\(bitsPerChannel), flags=\(flags)")
        return []
    }

    private static func readFloat32MonoSamples(
        from buffers: UnsafeMutableAudioBufferListPointer,
        channelCount: Int,
        isNonInterleaved: Bool
    ) -> [Float] {
        guard !buffers.isEmpty else { return [] }

        if isNonInterleaved, buffers.count > 1 {
            let frameCount = buffers
                .map { Int($0.mDataByteSize) / MemoryLayout<Float>.size }
                .min() ?? 0
            guard frameCount > 0 else { return [] }

            var samples = Array(repeating: Float.zero, count: frameCount)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let pointer = data.bindMemory(to: Float.self, capacity: count)
                for index in 0..<frameCount {
                    samples[index] += pointer[index]
                }
            }
            return samples.map { $0 / Float(buffers.count) }
        }

        guard let data = buffers[0].mData else { return [] }
        let valueCount = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        let pointer = data.bindMemory(to: Float.self, capacity: valueCount)
        if channelCount <= 1 {
            return Array(UnsafeBufferPointer(start: pointer, count: valueCount))
        }

        let frameCount = valueCount / channelCount
        return (0..<frameCount).map { frameIndex in
            let offset = frameIndex * channelCount
            let sum = (0..<channelCount).reduce(Float.zero) { partial, channelIndex in
                partial + pointer[offset + channelIndex]
            }
            return sum / Float(channelCount)
        }
    }

    private static func readInt16MonoSamples(
        from buffers: UnsafeMutableAudioBufferListPointer,
        channelCount: Int,
        isNonInterleaved: Bool
    ) -> [Float] {
        guard !buffers.isEmpty else { return [] }
        let scale = Float(Int16.max)

        if isNonInterleaved, buffers.count > 1 {
            let frameCount = buffers
                .map { Int($0.mDataByteSize) / MemoryLayout<Int16>.size }
                .min() ?? 0
            guard frameCount > 0 else { return [] }

            var samples = Array(repeating: Float.zero, count: frameCount)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let pointer = data.bindMemory(to: Int16.self, capacity: count)
                for index in 0..<frameCount {
                    samples[index] += Float(pointer[index]) / scale
                }
            }
            return samples.map { $0 / Float(buffers.count) }
        }

        guard let data = buffers[0].mData else { return [] }
        let valueCount = Int(buffers[0].mDataByteSize) / MemoryLayout<Int16>.size
        let pointer = data.bindMemory(to: Int16.self, capacity: valueCount)
        if channelCount <= 1 {
            return (0..<valueCount).map { Float(pointer[$0]) / scale }
        }

        let frameCount = valueCount / channelCount
        return (0..<frameCount).map { frameIndex in
            let offset = frameIndex * channelCount
            let sum = (0..<channelCount).reduce(Float.zero) { partial, channelIndex in
                partial + Float(pointer[offset + channelIndex]) / scale
            }
            return sum / Float(channelCount)
        }
    }

    private static func resampleMonoFloat32(
        _ samples: [Float],
        sourceSampleRate: Double,
        targetSampleRate: Double
    ) -> [Float]? {
        guard sourceSampleRate > 0, targetSampleRate > 0, !samples.isEmpty else {
            return nil
        }
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceSampleRate,
                channels: AVAudioChannelCount(targetChannelCount),
                interleaved: false
            ),
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: AVAudioChannelCount(targetChannelCount),
                interleaved: false
            ),
            let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else {
            return nil
        }

        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        guard let sourceChannel = sourceBuffer.floatChannelData?[0] else { return nil }
        for index in samples.indices {
            sourceChannel[index] = samples[index]
        }

        let ratio = targetSampleRate / sourceSampleRate
        let outputCapacity = max(AVAudioFrameCount(ceil(Double(samples.count) * ratio)) + 32, 1)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            return nil
        }

        let inputProvider = AudioConverterInputProvider(sourceBuffer: sourceBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            inputProvider.nextBuffer(outStatus: outStatus)
        }
        guard
            status != .error,
            conversionError == nil,
            let outputChannel = outputBuffer.floatChannelData?[0]
        else {
            if let conversionError {
                MLingoLogger.audio.error(
                    "Audio resampling failed: \(conversionError.localizedDescription, privacy: .public)"
                )
            }
            return nil
        }
        return Array(UnsafeBufferPointer(start: outputChannel, count: Int(outputBuffer.frameLength)))
    }
}

private final class AudioConverterInputProvider: @unchecked Sendable {
    private let sourceBuffer: AVAudioPCMBuffer
    private var didProvideSource = false

    init(sourceBuffer: AVAudioPCMBuffer) {
        self.sourceBuffer = sourceBuffer
    }

    func nextBuffer(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !didProvideSource else {
            outStatus.pointee = .endOfStream
            return nil
        }
        didProvideSource = true
        outStatus.pointee = .haveData
        return sourceBuffer
    }
}
