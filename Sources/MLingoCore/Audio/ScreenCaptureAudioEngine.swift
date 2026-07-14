import CoreMedia
import Foundation
import ScreenCaptureKit

public final class ScreenCaptureAudioEngine: NSObject, AudioEngineProtocol, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let targetSampleRate: Double = 16_000
    private static let targetChannelCount = 1
    private static let scStreamUserDeclinedCode = -3801
    private static let scStreamUserStoppedCode = -3817

    private let outputQueue = DispatchQueue(label: "com.duongvt.MLingo.audio-output")
    private let outputQueueKey = DispatchSpecificKey<Bool>()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var diagnosticsContinuation: AsyncStream<AudioCaptureDiagnostics>.Continuation?
    private var stream: SCStream?
    private var captureState: AudioCaptureState = .idle
    private var diagnosticsAccumulator = AudioCaptureDiagnosticsAccumulator(
        backend: .screenCaptureKit
    )

    public let chunks: AsyncStream<AudioChunk>
    public let diagnostics: AsyncStream<AudioCaptureDiagnostics>

    public override init() {
        var capturedContinuation: AsyncStream<AudioChunk>.Continuation?
        chunks = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        let (diagnostics, diagnosticsContinuation) = Self.makeDiagnosticsStream()
        self.diagnostics = diagnostics
        continuation = capturedContinuation
        self.diagnosticsContinuation = diagnosticsContinuation
        super.init()
        outputQueue.setSpecific(key: outputQueueKey, value: true)
    }

    static func makeDiagnosticsStream() -> (
        AsyncStream<AudioCaptureDiagnostics>,
        AsyncStream<AudioCaptureDiagnostics>.Continuation
    ) {
        AsyncStream.makeStream(
            of: AudioCaptureDiagnostics.self,
            bufferingPolicy: .bufferingNewest(1)
        )
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
            let mappedError = Self.mapStartError(error)
            let message = mappedError.localizedDescription
            updateDiagnostics(state: .failed(message))
            MLingoLogger.audio.error("ScreenCaptureKit audio capture failed: \(error.localizedDescription, privacy: .public)")
            throw mappedError
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
            return
        }

        continuation?.yield(chunk)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !Self.isScreenCaptureKitError(error, code: Self.scStreamUserStoppedCode) else {
            performOnOutputQueue {
                self.stream = nil
                captureState = .stopped
                _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.update(state: .stopped))
            }
            MLingoLogger.audio.debug("ScreenCaptureKit stream stopped by user")
            return
        }

        let failedState = AudioCaptureState.failed(error.localizedDescription)
        performOnOutputQueue {
            self.stream = nil
            captureState = failedState
            _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.update(state: failedState))
        }
        MLingoLogger.audio.error("ScreenCaptureKit stream stopped with error: \(error.localizedDescription, privacy: .public)")
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

        let normalizedSamples = withUnsafePointer(to: &audioBufferList) {
            AudioPCMNormalizer.normalize(
                bufferList: $0,
                streamDescription: streamDescription
            )
        }
        guard let normalizedSamples else {
            MLingoLogger.audio.error("Audio normalization returned no samples; dropping chunk")
            return nil
        }
        guard !normalizedSamples.isEmpty else {
            return AudioChunk(
                samples: [],
                sampleRate: Self.targetSampleRate,
                channelCount: Self.targetChannelCount,
                timestamp: sampleBuffer.presentationTimeStamp.seconds,
                duration: sampleBuffer.duration.isValid ? sampleBuffer.duration.seconds : 0
            )
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

    private static func mapStartError(_ error: Error) -> MLingoError {
        if let mlingoError = error as? MLingoError {
            return mlingoError
        }

        if isScreenCaptureKitError(error, code: scStreamUserDeclinedCode) {
            return .permissionDenied("Cấp quyền Screen Recording cho MLingo trong System Settings > Privacy & Security > Screen Recording, rồi restart capture.")
        }

        return .captureFailed(error.localizedDescription)
    }

    private static func isScreenCaptureKitError(_ error: Error, code: Int) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain && nsError.code == code
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
            _ = diagnosticsAccumulator.recordCapturedChunk(chunk, level: level)
            if level.isSpeechLike {
                _ = diagnosticsAccumulator.recordSpeechLikeChunk()
            } else {
                _ = diagnosticsAccumulator.recordDroppedChunk()
            }
            _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.diagnostics)
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

    private func performOnOutputQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: outputQueueKey) == true {
            return operation()
        }
        return outputQueue.sync(execute: operation)
    }
}
