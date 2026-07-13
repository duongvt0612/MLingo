import Foundation

public final class MLXWhisperEngine: WhisperEngineProtocol, @unchecked Sendable {
    private var loadedModelName: String?

    public init() {}

    public func loadModel(named modelName: String) async throws {
        guard !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MLingoError.whisperModelUnavailable("Choose a Whisper model in Settings.")
        }

        loadedModelName = modelName
    }

    public func transcribe(_ chunk: AudioChunk) async throws -> Transcript? {
        guard loadedModelName != nil else {
            throw MLingoError.whisperModelUnavailable("Load a Whisper model before starting capture.")
        }

        let rms = rootMeanSquare(chunk.samples)
        guard rms > 0.015 else {
            return nil
        }

        throw MLingoError.whisperIntegrationPending(
            "MLX Whisper model inference is not wired yet. Audio capture is producing speech-like chunks."
        )
    }

    private func rootMeanSquare(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float.zero) { partial, sample in
            partial + sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }
}
