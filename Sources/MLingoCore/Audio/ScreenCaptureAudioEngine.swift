@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

public final class ScreenCaptureAudioEngine: NSObject, AudioEngineProtocol, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let targetSampleRate: Double = 16_000
    private static let targetChannelCount = 1

    private let outputQueue = DispatchQueue(label: "com.duongvt.MLingo.audio-output")
    private let outputQueueKey = DispatchSpecificKey<Bool>()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var diagnosticsContinuation: AsyncStream<AudioCaptureDiagnostics>.Continuation?
    private var stream: SCStream?
    private var captureState: AudioCaptureState = .idle
    private var diagnosticsAccumulator = AudioCaptureDiagnosticsAccumulator()

    public let chunks: AsyncStream<AudioChunk>
    public let diagnostics: AsyncStream<AudioCaptureDiagnostics>

    public override init() {
        var capturedContinuation: AsyncStream<AudioChunk>.Continuation?
        var capturedDiagnosticsContinuation: AsyncStream<AudioCaptureDiagnostics>.Continuation?
        chunks = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        diagnostics = AsyncStream { continuation in
            capturedDiagnosticsContinuation = continuation
        }
        continuation = capturedContinuation
        diagnosticsContinuation = capturedDiagnosticsContinuation
        super.init()
        outputQueue.setSpecific(key: outputQueueKey, value: true)
    }

    public var state: AudioCaptureState {
        get async {
            performOnOutputQueue {
                captureState
            }
        }
    }

    public func start() async throws {
        MLingoLogger.audio.info("Starting ScreenCaptureKit audio capture")
        resetDiagnostics(state: .requestingPermission)

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            guard let display = content.displays.first else {
                updateDiagnostics(state: .failed(MLingoError.noAudioSource.localizedDescription))
                MLingoLogger.audio.error("No capturable display is available")
                throw MLingoError.noAudioSource
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = max(display.width, 2)
            configuration.height = max(display.height, 2)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = Int(Self.targetSampleRate)
            configuration.channelCount = Self.targetChannelCount

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()

            performOnOutputQueue {
                self.stream = stream
                captureState = .running
                _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.update(state: .running))
            }
            MLingoLogger.audio.info("ScreenCaptureKit audio capture started with display size \(display.width, privacy: .public)x\(display.height, privacy: .public)")
        } catch {
            let message = error.localizedDescription
            updateDiagnostics(state: .failed(message))
            MLingoLogger.audio.error("ScreenCaptureKit audio capture failed: \(message, privacy: .public)")
            if message.localizedCaseInsensitiveContains("permission") {
                throw MLingoError.permissionDenied("Cấp quyền Screen Recording cho MLingo trong System Settings > Privacy & Security > Screen Recording, rồi restart capture.")
            }
            throw MLingoError.captureFailed(message)
        }
    }

    public func stop() async {
        let currentStream = performOnOutputQueue {
            stream
        }

        guard let currentStream else {
            updateDiagnostics(state: .stopped)
            MLingoLogger.audio.debug("Stop requested while audio capture is not running")
            return
        }

        do {
            try await currentStream.stopCapture()
        } catch {
            updateDiagnostics(state: .failed(error.localizedDescription))
            MLingoLogger.audio.error("Stopping ScreenCaptureKit audio capture failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        performOnOutputQueue {
            self.stream = nil
            captureState = .stopped
            _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.update(state: .stopped))
        }
        MLingoLogger.audio.info("ScreenCaptureKit audio capture stopped")
    }

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        guard let chunk = Self.makeChunk(from: sampleBuffer) else {
            recordDroppedChunk()
            return
        }

        guard !chunk.samples.isEmpty else {
            recordEmptyChunk()
            return
        }

        let level = AudioLevelAnalyzer.analyze(samples: chunk.samples)
        recordCapturedChunk(chunk, level: level)

        guard level.isSpeechLike else {
            recordDroppedChunk()
            return
        }

        recordSpeechLikeChunk()
        continuation?.yield(chunk)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let failedState = AudioCaptureState.failed(error.localizedDescription)
        performOnOutputQueue {
            captureState = failedState
            _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.update(state: failedState))
        }
        MLingoLogger.audio.error("ScreenCaptureKit stream stopped with error: \(error.localizedDescription, privacy: .public)")
        continuation?.finish()
        diagnosticsContinuation?.finish()
    }

    private static func makeChunk(from sampleBuffer: CMSampleBuffer) -> AudioChunk? {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }

        let streamDescription = streamDescriptionPointer.pointee
        var audioBufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, audioBufferList.mBuffers.mData != nil else {
            return nil
        }

        let samples = readMonoSamples(
            from: &audioBufferList,
            streamDescription: streamDescription
        )
        guard !samples.isEmpty else {
            return AudioChunk(
                samples: [],
                sampleRate: Self.targetSampleRate,
                channelCount: Self.targetChannelCount,
                timestamp: sampleBuffer.presentationTimeStamp.seconds,
                duration: sampleBuffer.duration.isValid ? sampleBuffer.duration.seconds : 0
            )
        }

        let normalizedSamples: [Float]
        if streamDescription.mSampleRate == Self.targetSampleRate {
            normalizedSamples = samples
        } else {
            guard let convertedSamples = resampleMonoFloat32(
                samples,
                sourceSampleRate: streamDescription.mSampleRate,
                targetSampleRate: Self.targetSampleRate
            ) else {
                MLingoLogger.audio.error("Audio resampling returned no samples; dropping chunk")
                return nil
            }
            normalizedSamples = convertedSamples
        }

        let timestamp = sampleBuffer.presentationTimeStamp.seconds
        let duration = sampleBuffer.duration.isValid ? sampleBuffer.duration.seconds : 0

        return AudioChunk(
            samples: normalizedSamples,
            sampleRate: Self.targetSampleRate,
            channelCount: Self.targetChannelCount,
            timestamp: timestamp,
            duration: duration
        )
    }

    private static func readMonoSamples(
        from audioBufferList: inout AudioBufferList,
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
                from: &audioBufferList,
                channelCount: channelCount,
                isNonInterleaved: isNonInterleaved
            )
        }

        if isSignedInteger, bitsPerChannel == 16 {
            return readInt16MonoSamples(
                from: &audioBufferList,
                channelCount: channelCount,
                isNonInterleaved: isNonInterleaved
            )
        }

        MLingoLogger.audio.error("Unsupported audio format: bits=\(bitsPerChannel), flags=\(flags)")
        return []
    }

    private static func readFloat32MonoSamples(
        from audioBufferList: inout AudioBufferList,
        channelCount: Int,
        isNonInterleaved: Bool
    ) -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
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
        from audioBufferList: inout AudioBufferList,
        channelCount: Int,
        isNonInterleaved: Bool
    ) -> [Float] {
        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
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
                channels: AVAudioChannelCount(Self.targetChannelCount),
                interleaved: false
            ),
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: AVAudioChannelCount(Self.targetChannelCount),
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
        guard let sourceChannel = sourceBuffer.floatChannelData?[0] else {
            return nil
        }

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

        guard status != .error, conversionError == nil, let outputChannel = outputBuffer.floatChannelData?[0] else {
            if let conversionError {
                MLingoLogger.audio.error("Audio resampling failed: \(conversionError.localizedDescription, privacy: .public)")
            }
            return nil
        }

        return Array(UnsafeBufferPointer(start: outputChannel, count: Int(outputBuffer.frameLength)))
    }

    private func resetDiagnostics(state: AudioCaptureState) {
        performOnOutputQueue {
            captureState = state
            _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.reset(state: state))
        }
    }

    private func updateDiagnostics(state: AudioCaptureState) {
        performOnOutputQueue {
            captureState = state
            _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.update(state: state))
        }
    }

    private func recordCapturedChunk(_ chunk: AudioChunk, level: AudioLevel) {
        performOnOutputQueue {
            _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.recordCapturedChunk(chunk, level: level))
        }
    }

    private func recordDroppedChunk() {
        performOnOutputQueue {
            _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.recordDroppedChunk())
        }
    }

    private func recordEmptyChunk() {
        performOnOutputQueue {
            _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.recordEmptyChunk())
        }
    }

    private func recordSpeechLikeChunk() {
        performOnOutputQueue {
            _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.recordSpeechLikeChunk())
        }
    }

    private func performOnOutputQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: outputQueueKey) == true {
            return operation()
        }
        return outputQueue.sync(execute: operation)
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
            outStatus.pointee = .noDataNow
            return nil
        }

        didProvideSource = true
        outStatus.pointee = .haveData
        return sourceBuffer
    }
}
