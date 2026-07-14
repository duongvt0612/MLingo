import Foundation

@available(macOS 14.2, *)
public final class CoreAudioTapEngine: AudioEngineProtocol, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "com.duongvt.MLingo.core-audio-state")
    private let stateQueueKey = DispatchSpecificKey<Bool>()
    private let session: CoreAudioTapSession
    private var chunkContinuation: AsyncStream<AudioChunk>.Continuation?
    private var diagnosticsContinuation: AsyncStream<AudioCaptureDiagnostics>.Continuation?
    private var captureState: AudioCaptureState = .idle
    private var diagnosticsAccumulator = AudioCaptureDiagnosticsAccumulator()

    public let chunks: AsyncStream<AudioChunk>
    public let diagnostics: AsyncStream<AudioCaptureDiagnostics>

    public convenience init() {
        self.init(hal: SystemCoreAudioHAL())
    }

    init(hal: any CoreAudioHALProtocol) {
        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (diagnostics, diagnosticsContinuation) = AsyncStream.makeStream(
            of: AudioCaptureDiagnostics.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.chunks = chunks
        self.diagnostics = diagnostics
        self.chunkContinuation = chunkContinuation
        self.diagnosticsContinuation = diagnosticsContinuation
        session = CoreAudioTapSession(hal: hal)
        stateQueue.setSpecific(key: stateQueueKey, value: true)
    }

    public var state: AudioCaptureState {
        get async {
            performOnStateQueue { captureState }
        }
    }

    public func start() async throws {
        MLingoLogger.audio.info("Starting Core Audio system tap")
        resetDiagnostics(state: .requestingPermission)
        do {
            try session.start { [weak self] samples, sampleRate, timestamp in
                self?.receive(samples: samples, sampleRate: sampleRate, timestamp: timestamp)
            }
            updateDiagnostics(state: .running)
            MLingoLogger.audio.info("Core Audio system tap started")
        } catch {
            let mappedError = Self.mapStartError(error)
            updateDiagnostics(state: .failed(mappedError.localizedDescription))
            MLingoLogger.audio.error(
                "Core Audio system tap failed: \(mappedError.localizedDescription, privacy: .public)"
            )
            throw mappedError
        }
    }

    public func stop() async {
        session.stop()
        updateDiagnostics(state: .stopped)
        chunkContinuation?.finish()
        diagnosticsContinuation?.finish()
        MLingoLogger.audio.info("Core Audio system tap stopped")
    }

    private func receive(samples: [Float], sampleRate: Double, timestamp: TimeInterval) {
        guard !samples.isEmpty else {
            performOnStateQueue {
                _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.recordEmptyChunk())
            }
            return
        }

        let chunk = AudioChunk(
            samples: samples,
            sampleRate: sampleRate,
            channelCount: AudioPCMNormalizer.targetChannelCount,
            timestamp: timestamp,
            duration: TimeInterval(samples.count) / sampleRate
        )
        let level = AudioLevelAnalyzer.analyze(samples: samples)
        performOnStateQueue {
            guard captureState == .running else { return }
            _ = diagnosticsAccumulator.recordCapturedChunk(chunk, level: level)
            if level.isSpeechLike {
                _ = diagnosticsAccumulator.recordSpeechLikeChunk()
            } else {
                _ = diagnosticsAccumulator.recordDroppedChunk()
            }
            _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.diagnostics)
            if level.isSpeechLike {
                _ = chunkContinuation?.yield(chunk)
            }
        }
    }

    private static func mapStartError(_ error: Error) -> MLingoError {
        if let error = error as? MLingoError {
            return error
        }
        return .captureFailed(error.localizedDescription)
    }

    private func resetDiagnostics(state: AudioCaptureState) {
        performOnStateQueue {
            captureState = state
            _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.reset(state: state))
        }
    }

    private func updateDiagnostics(state: AudioCaptureState) {
        performOnStateQueue {
            captureState = state
            _ = diagnosticsContinuation?.yield(diagnosticsAccumulator.update(state: state))
        }
    }

    private func performOnStateQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) == true {
            return operation()
        }
        return stateQueue.sync(execute: operation)
    }
}
