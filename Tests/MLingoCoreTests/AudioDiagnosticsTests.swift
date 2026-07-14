import AudioToolbox
import Foundation
import Testing
@testable import MLingoCore

@Test
func audioLevelAnalyzerComputesRMSPeakAndSpeechFlag() {
    let level = AudioLevelAnalyzer.analyze(
        samples: [0.0, 0.03, -0.03, 0.0],
        vadThreshold: 0.015
    )

    #expect(abs(level.rms - 0.0212) < 0.001)
    #expect(abs(level.peak - 0.03) < 0.001)
    #expect(level.isSpeechLike)
}

@Test
func audioLevelAnalyzerDropsSilenceBelowThreshold() {
    let level = AudioLevelAnalyzer.analyze(
        samples: [0.001, -0.001, 0.0],
        vadThreshold: 0.015
    )

    #expect(level.rms < 0.015)
    #expect(!level.isSpeechLike)
}

@Test
func diagnosticsAccumulatorTracksChunkCounters() {
    var accumulator = AudioCaptureDiagnosticsAccumulator(backend: .coreAudioTap)
    let chunk = AudioChunk(
        samples: [0.02, -0.02],
        sampleRate: 16_000,
        channelCount: 1,
        timestamp: 1,
        duration: 0.02
    )
    let level = AudioLevelAnalyzer.analyze(samples: chunk.samples)

    _ = accumulator.update(state: .running)
    _ = accumulator.recordCapturedChunk(chunk, level: level)
    _ = accumulator.recordSpeechLikeChunk()
    _ = accumulator.recordDroppedChunk()
    _ = accumulator.recordEmptyChunk()

    let diagnostics = accumulator.diagnostics
    #expect(diagnostics.state == .running)
    #expect(diagnostics.capturedChunkCount == 1)
    #expect(diagnostics.speechLikeChunkCount == 1)
    #expect(diagnostics.droppedChunkCount == 1)
    #expect(diagnostics.emptyChunkCount == 1)
    #expect(diagnostics.sampleRate == 16_000)
    #expect(diagnostics.channelCount == 1)
    #expect(diagnostics.backend == .coreAudioTap)

    let reset = accumulator.reset(state: .requestingPermission)
    #expect(reset.backend == .coreAudioTap)
}

@Test
func pcmNormalizerDownmixesStereoFloat32() {
    var interleavedSamples: [Float] = [1, -1, 0.5, 0.5, -0.25, 0.75]
    let normalized = interleavedSamples.withUnsafeMutableBytes { bytes -> [Float]? in
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: UInt32(bytes.count),
                mData: bytes.baseAddress
            )
        )
        let format = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        return withUnsafePointer(to: &bufferList) {
            AudioPCMNormalizer.normalize(bufferList: $0, streamDescription: format)
        }
    }

    #expect(normalized == [0, 0.5, 0.25])
}

@Test
func pcmNormalizerResamplesToSixteenKilohertz() {
    var sourceSamples = (0..<480).map { index in
        Float(sin(Double(index) * 2 * .pi / 48))
    }
    let normalized = sourceSamples.withUnsafeMutableBytes { bytes -> [Float]? in
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(bytes.count),
                mData: bytes.baseAddress
            )
        )
        let format = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        return withUnsafePointer(to: &bufferList) {
            AudioPCMNormalizer.normalize(bufferList: $0, streamDescription: format)
        }
    }

    #expect(normalized != nil)
    #expect((150...170).contains(normalized?.count ?? 0))
}

@Test
func diagnosticsStreamDropsStaleSnapshots() async {
    let (stream, continuation) = ScreenCaptureAudioEngine.makeDiagnosticsStream()

    continuation.yield(AudioCaptureDiagnostics(capturedChunkCount: 1))
    continuation.yield(AudioCaptureDiagnostics(capturedChunkCount: 2))
    continuation.yield(AudioCaptureDiagnostics(capturedChunkCount: 3))
    continuation.finish()

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next()?.capturedChunkCount == 3)
    #expect(await iterator.next() == nil)
}
