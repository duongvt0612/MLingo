import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

public final class ScreenCaptureAudioEngine: NSObject, AudioEngineProtocol, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let outputQueue = DispatchQueue(label: "com.duongvt.MLingo.audio-output")
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var stream: SCStream?
    private var captureState: AudioCaptureState = .idle

    public let chunks: AsyncStream<AudioChunk>

    public override init() {
        var capturedContinuation: AsyncStream<AudioChunk>.Continuation?
        chunks = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation
        super.init()
    }

    public var state: AudioCaptureState {
        get async { captureState }
    }

    public func start() async throws {
        MLingoLogger.audio.info("Starting ScreenCaptureKit audio capture")
        captureState = .requestingPermission

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            guard let display = content.displays.first else {
                captureState = .failed(MLingoError.noAudioSource.localizedDescription)
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
            configuration.sampleRate = 16_000
            configuration.channelCount = 1

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()

            self.stream = stream
            captureState = .running
            MLingoLogger.audio.info("ScreenCaptureKit audio capture started with display size \(display.width)x\(display.height)")
        } catch {
            let message = error.localizedDescription
            captureState = .failed(message)
            MLingoLogger.audio.error("ScreenCaptureKit audio capture failed: \(message, privacy: .public)")
            if message.localizedCaseInsensitiveContains("permission") {
                throw MLingoError.permissionDenied("Allow Screen Recording for MLingo in System Settings, then restart capture.")
            }
            throw MLingoError.captureFailed(message)
        }
    }

    public func stop() async {
        guard let stream else {
            captureState = .stopped
            MLingoLogger.audio.debug("Stop requested while audio capture is not running")
            return
        }

        do {
            try await stream.stopCapture()
        } catch {
            captureState = .failed(error.localizedDescription)
            MLingoLogger.audio.error("Stopping ScreenCaptureKit audio capture failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        self.stream = nil
        captureState = .stopped
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
            return
        }

        continuation?.yield(chunk)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        captureState = .failed(error.localizedDescription)
        MLingoLogger.audio.error("ScreenCaptureKit stream stopped with error: \(error.localizedDescription, privacy: .public)")
        continuation?.finish()
    }

    private static func makeChunk(from sampleBuffer: CMSampleBuffer) -> AudioChunk? {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }

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

        guard status == noErr, let data = audioBufferList.mBuffers.mData else {
            return nil
        }

        let frameCount = Int(audioBufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        let pointer = data.bindMemory(to: Float.self, capacity: frameCount)
        let samples = Array(UnsafeBufferPointer(start: pointer, count: frameCount))
        let timestamp = sampleBuffer.presentationTimeStamp.seconds
        let duration = sampleBuffer.duration.isValid ? sampleBuffer.duration.seconds : 0

        return AudioChunk(
            samples: samples,
            sampleRate: streamDescription.pointee.mSampleRate,
            channelCount: Int(streamDescription.pointee.mChannelsPerFrame),
            timestamp: timestamp,
            duration: duration
        )
    }
}
