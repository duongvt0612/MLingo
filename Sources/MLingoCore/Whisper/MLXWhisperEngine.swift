import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT

protocol WhisperInferenceBackend: Sendable {
    func loadModel(named modelName: String) async throws
    func transcribe(samples: [Float], language: String) async throws -> String
}

actor MLXAudioWhisperBackend: WhisperInferenceBackend {
    private var model: WhisperModel?

    func loadModel(named modelName: String) async throws {
        model = try await WhisperModel.fromPretrained(
            Self.resolvedModelName(for: modelName)
        )
    }

    static func resolvedModelName(for modelName: String) -> String {
        switch modelName {
        case "mlx-community/whisper-base-mlx":
            "mlx-community/whisper-base-asr-fp16"
        case "mlx-community/whisper-small-mlx":
            "mlx-community/whisper-small-asr-fp16"
        default:
            modelName
        }
    }

    func transcribe(samples: [Float], language: String) async throws -> String {
        guard let model else {
            throw MLingoError.whisperModelUnavailable(
                "Load a Whisper model before starting transcription."
            )
        }

        let output = model.generate(
            audio: MLXArray(samples),
            generationParameters: STTGenerateParameters(language: language)
        )
        return output.text
    }
}

public actor MLXWhisperEngine: WhisperEngineProtocol {
    private let backend: any WhisperInferenceBackend
    private var loadedModelName: String?

    public init() {
        backend = MLXAudioWhisperBackend()
    }

    init(backend: any WhisperInferenceBackend) {
        self.backend = backend
    }

    public func loadModel(named modelName: String) async throws {
        let normalizedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw MLingoError.whisperModelLoadFailed(
                "Choose a valid Hugging Face Whisper model in Settings."
            )
        }

        guard loadedModelName != normalizedName else { return }

        do {
            try await backend.loadModel(named: normalizedName)
            loadedModelName = normalizedName
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MLingoError.whisperModelLoadFailed(
                "Could not load Whisper model \(normalizedName). Check the model ID and network connection. \(error.localizedDescription)"
            )
        }
    }

    public func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript? {
        guard loadedModelName != nil else {
            throw MLingoError.whisperModelUnavailable(
                "Load a Whisper model before starting transcription."
            )
        }

        guard !chunk.samples.isEmpty else { return nil }

        do {
            let text = try await backend.transcribe(
                samples: chunk.samples,
                language: language
            )
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return nil }
            return Transcript(text: trimmedText, timestamp: chunk.timestamp)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MLingoError {
            throw error
        } catch {
            throw MLingoError.whisperInferenceFailed(
                "Whisper could not transcribe the current audio window. \(error.localizedDescription)"
            )
        }
    }
}
