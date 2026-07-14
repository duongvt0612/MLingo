import Foundation

public struct AudioCaptureDiagnosticsAccumulator: Sendable {
    public private(set) var diagnostics: AudioCaptureDiagnostics

    public init(
        diagnostics: AudioCaptureDiagnostics = AudioCaptureDiagnostics(),
        backend: AudioCaptureBackend? = nil
    ) {
        var diagnostics = diagnostics
        diagnostics.backend = backend ?? diagnostics.backend
        self.diagnostics = diagnostics
    }

    public mutating func reset(state: AudioCaptureState) -> AudioCaptureDiagnostics {
        diagnostics = AudioCaptureDiagnostics(backend: diagnostics.backend, state: state)
        return diagnostics
    }

    public mutating func update(state: AudioCaptureState) -> AudioCaptureDiagnostics {
        diagnostics.state = state
        diagnostics.lastUpdated = Date()
        return diagnostics
    }

    public mutating func recordCapturedChunk(_ chunk: AudioChunk, level: AudioLevel) -> AudioCaptureDiagnostics {
        diagnostics.rms = level.rms
        diagnostics.peak = level.peak
        diagnostics.sampleRate = chunk.sampleRate
        diagnostics.channelCount = chunk.channelCount
        diagnostics.lastChunkDuration = chunk.duration
        diagnostics.capturedChunkCount += 1
        diagnostics.lastUpdated = Date()
        return diagnostics
    }

    public mutating func recordDroppedChunk() -> AudioCaptureDiagnostics {
        diagnostics.droppedChunkCount += 1
        diagnostics.lastUpdated = Date()
        return diagnostics
    }

    public mutating func recordEmptyChunk() -> AudioCaptureDiagnostics {
        diagnostics.emptyChunkCount += 1
        diagnostics.lastUpdated = Date()
        return diagnostics
    }

    public mutating func recordSpeechLikeChunk() -> AudioCaptureDiagnostics {
        diagnostics.speechLikeChunkCount += 1
        diagnostics.lastUpdated = Date()
        return diagnostics
    }
}
