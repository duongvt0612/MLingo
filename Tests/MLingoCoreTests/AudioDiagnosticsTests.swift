import AudioToolbox
@preconcurrency import AVFoundation
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
    var accumulator = AudioCaptureDiagnosticsAccumulator(
        diagnostics: AudioCaptureDiagnostics(vadThreshold: 0.003),
        backend: .coreAudioTap
    )
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
    #expect(reset.vadThreshold == 0.003)
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
func pcmNormalizerDownmixesNonInterleavedStereoBuffers() throws {
    let format = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 2,
            interleaved: false
        )
    )
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)
    )
    buffer.frameLength = 2
    let channelData = try #require(buffer.floatChannelData)
    channelData[0][0] = 1
    channelData[0][1] = 0.25
    channelData[1][0] = -1
    channelData[1][1] = 0.75

    let normalized = AudioPCMNormalizer.normalize(
        bufferList: buffer.audioBufferList,
        streamDescription: format.streamDescription.pointee
    )

    #expect(normalized == [0, 0.5])
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
func coreAudioBatcherCombinesRealtimeCallbacksWithoutDroppingSamples() {
    var batcher = CoreAudioSampleBatcher(targetDuration: 0.1)
    var batches: [CoreAudioSampleBatch] = []

    for callbackIndex in 0..<21 {
        batches.append(
            contentsOf: batcher.append(
                samples: Array(repeating: Float(callbackIndex), count: 480),
                sampleRate: 48_000,
                timestamp: Double(callbackIndex) * 0.01
            )
        )
    }

    #expect(batches.count == 2)
    #expect(batches.map(\.samples.count) == [4_800, 4_800])
    #expect(abs(batches[0].timestamp - 0) < 0.0001)
    #expect(abs(batches[1].timestamp - 0.1) < 0.0001)
    #expect(batcher.bufferedSampleCount == 480)
    #expect(batches.flatMap(\.samples).count + batcher.bufferedSampleCount == 10_080)
}

@Test(arguments: [1.0, 0.02])
func coreAudioBatcherSeparatesTimestampDiscontinuities(nextTimestamp: TimeInterval) throws {
    var batcher = CoreAudioSampleBatcher(targetDuration: 0.1)
    #expect(
        batcher.append(
            samples: Array(repeating: 1, count: 2_400),
            sampleRate: 48_000,
            timestamp: 0
        ).isEmpty
    )

    let flushed = batcher.append(
        samples: Array(repeating: 2, count: 2_400),
        sampleRate: 48_000,
        timestamp: nextTimestamp
    )
    let oldBatch = try #require(flushed.first)
    let pendingBatch = batcher.flush()
    let newBatch = try #require(pendingBatch)

    #expect(flushed.count == 1)
    #expect(oldBatch.timestamp == 0)
    #expect(oldBatch.samples == Array(repeating: 1, count: 2_400))
    #expect(newBatch.timestamp == nextTimestamp)
    #expect(newBatch.samples == Array(repeating: 2, count: 2_400))
}

@Test
func systemAudioPermissionErrorUsesEnglishSystemSettingsLabels() {
    let message = MLingoError.systemAudioPermissionDenied.localizedDescription

    #expect(message.contains("Allow"))
    #expect(message.contains("System Settings > Privacy & Security > Screen & System Audio Recording"))
    #expect(!message.contains("Cấp quyền"))
}

@Test
func streamingResamplerPreservesContinuousCoreAudioBatches() {
    let resampler = StreamingMonoResampler(targetSampleRate: 16_000)
    let inputBatches = (0..<10).map { batchIndex in
        (0..<4_800).map { sampleIndex in
            let absoluteIndex = batchIndex * 4_800 + sampleIndex
            return Float(sin(Double(absoluteIndex) * 2 * .pi / 480))
        }
    }
    let completeInput = inputBatches.flatMap { $0 }
    let referenceSamples = AudioPCMNormalizer.resampleMono(
        completeInput,
        sourceSampleRate: 48_000
    ) ?? []
    var outputSamples: [Float] = []
    var outputBoundaries: [Int] = []

    for input in inputBatches {
        let output = resampler.convert(input, sourceSampleRate: 48_000)
        #expect(output != nil)
        outputSamples.append(contentsOf: output ?? [])
        outputBoundaries.append(outputSamples.count)
    }

    #expect((15_700...16_100).contains(outputSamples.count))
    #expect(outputSamples.contains { abs($0) > 0.5 })
    #expect((15_700...16_100).contains(referenceSamples.count))

    let latencyOffset = bestReferenceOffset(
        streaming: outputSamples,
        reference: referenceSamples,
        maximumOffset: 64
    )
    #expect(abs(latencyOffset) <= 64)

    let aggregateError = meanAbsoluteReferenceError(
        streaming: outputSamples,
        reference: referenceSamples,
        offset: latencyOffset,
        indices: stride(from: 0, to: outputSamples.count, by: 17)
    )
    #expect(aggregateError < 0.01)

    for boundary in outputBoundaries.dropLast() {
        let boundaryIndices = max(0, boundary - 12)..<min(outputSamples.count, boundary + 12)
        let boundaryError = meanAbsoluteReferenceError(
            streaming: outputSamples,
            reference: referenceSamples,
            offset: latencyOffset,
            indices: boundaryIndices
        )
        #expect(boundaryError < 0.02)
    }
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

private func bestReferenceOffset(
    streaming: [Float],
    reference: [Float],
    maximumOffset: Int
) -> Int {
    (-maximumOffset...maximumOffset).min { lhs, rhs in
        meanAbsoluteReferenceError(
            streaming: streaming,
            reference: reference,
            offset: lhs,
            indices: stride(from: 0, to: streaming.count, by: 31)
        ) < meanAbsoluteReferenceError(
            streaming: streaming,
            reference: reference,
            offset: rhs,
            indices: stride(from: 0, to: streaming.count, by: 31)
        )
    } ?? 0
}

private func meanAbsoluteReferenceError<S: Sequence>(
    streaming: [Float],
    reference: [Float],
    offset: Int,
    indices: S
) -> Double where S.Element == Int {
    var totalError = 0.0
    var comparedSampleCount = 0
    for streamingIndex in indices {
        let referenceIndex = streamingIndex + offset
        guard streaming.indices.contains(streamingIndex),
              reference.indices.contains(referenceIndex)
        else {
            continue
        }
        totalError += Double(abs(streaming[streamingIndex] - reference[referenceIndex]))
        comparedSampleCount += 1
    }
    guard comparedSampleCount > 0 else { return .infinity }
    return totalError / Double(comparedSampleCount)
}
