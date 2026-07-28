import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT

protocol WhisperInferenceBackend: Sendable {
    func loadModel(named modelName: String) async throws
    func transcribe(samples: [Float], language: String) async throws -> String
    /// Drops the loaded weights. Model Manager asks before deleting a model's files, because
    /// removing them while they are still mapped fails later and somewhere else.
    func unload() async
    /// The installed directory currently loaded, when the model came from the model store.
    func loadedModelDirectory() async -> URL?
}

/// Where a Whisper model is loaded from.
enum WhisperModelSource: Equatable, Sendable {
    /// A directory the Model Manager installed and verified. Loads without touching the network.
    case installedDirectory(URL)
    /// The repository identifier, resolved and downloaded by mlx-audio as before.
    case pretrained(String)
}

actor MLXAudioWhisperBackend: WhisperInferenceBackend {
    private static let whisperSampleRate = 16_000
    private let isMetalLibraryAvailable: @Sendable () -> Bool
    private let cache: HubCache
    private let modelDirectoryResolver: (any ModelDirectoryResolving)?
    private var model: WhisperModel?
    private var loadedDirectory: URL?

    /// `modelDirectoryResolver` defaults to `nil` so every existing call site keeps the previous
    /// behaviour untouched: without it the backend downloads through mlx-audio exactly as before,
    /// which is what keeps an installation that predates the model store working offline.
    init(
        cacheDirectory: URL? = nil,
        modelDirectoryResolver: (any ModelDirectoryResolving)? = nil,
        isMetalLibraryAvailable: @escaping @Sendable () -> Bool = {
            MLXMetalLibraryAvailability.isAvailable()
        }
    ) {
        cache = cacheDirectory.map(HubCache.init(cacheDirectory:)) ?? .default
        self.modelDirectoryResolver = modelDirectoryResolver
        self.isMetalLibraryAvailable = isMetalLibraryAvailable
    }

    /// Prefers an installed model and falls back to downloading, so the choice is a pure function
    /// of the resolver's answer and can be tested without MLX.
    static func resolveSource(
        for modelName: String,
        using resolver: (any ModelDirectoryResolving)?
    ) async -> WhisperModelSource {
        let repository = resolvedModelName(for: modelName)
        guard let resolver else { return .pretrained(repository) }
        // Both the catalog identifier and the alias it resolves to are accepted, because settings
        // stores the former while mlx-audio speaks the latter.
        if let directory = await resolver.installedDirectory(forModelID: modelName) {
            return .installedDirectory(directory)
        }
        if let directory = await resolver.installedDirectory(forModelID: repository) {
            return .installedDirectory(directory)
        }
        return .pretrained(repository)
    }

    func loadModel(named modelName: String) async throws {
        guard isMetalLibraryAvailable() else {
            throw MLingoError.whisperModelLoadFailed(
                "MLX Metal shaders are missing from this build. `swift run` does not package mlx-swift Metal resources. Install the Metal Toolchain and run the MLingo scheme in Xcode."
            )
        }

        switch await Self.resolveSource(for: modelName, using: modelDirectoryResolver) {
        case .installedDirectory(let directory):
            model = try await WhisperModel.fromDirectory(directory, cache: cache)
            loadedDirectory = directory
        case .pretrained(let repository):
            model = try await WhisperModel.fromPretrained(repository, cache: cache)
            loadedDirectory = nil
        }
    }

    func unload() {
        model = nil
        loadedDirectory = nil
    }

    func loadedModelDirectory() -> URL? {
        loadedDirectory
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

    static func maximumTokenCount(sampleCount: Int) -> Int {
        let duration = Double(max(sampleCount, 0)) / Double(whisperSampleRate)
        return min(128, max(48, Int(ceil(duration * 16))))
    }

    func transcribe(samples: [Float], language: String) async throws -> String {
        guard let model else {
            throw MLingoError.whisperModelUnavailable(
                "Load a Whisper model before starting transcription."
            )
        }

        let generationParameters = STTGenerateParameters(
            maxTokens: Self.maximumTokenCount(sampleCount: samples.count),
            temperature: 0,
            topP: 1,
            topK: 0,
            verbose: false,
            language: language,
            chunkDuration: 30,
            minChunkDuration: 0.1,
            repetitionPenalty: 1,
            repetitionContextSize: 32
        )
        let output = model.generate(
            audio: MLXArray(samples),
            generationParameters: generationParameters
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

    /// Loads from the model store when the identifier is installed, downloading otherwise.
    public init(modelDirectoryResolver: any ModelDirectoryResolving) {
        backend = MLXAudioWhisperBackend(modelDirectoryResolver: modelDirectoryResolver)
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
        } catch let error as MLingoError {
            throw error
        } catch {
            throw MLingoError.whisperModelLoadFailed(
                "Could not load Whisper model \(normalizedName). Check the model ID and network connection. \(String(describing: error))"
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

/// Residency reporting for the Model Manager.
///
/// The engine has no lease of its own: it holds one model for whatever session is running, and
/// cannot tell whether that session is mid-sentence. `leaseCount` therefore always reports zero
/// and protection comes from the lease the runtime takes through `ModelManager` for the length of
/// a session. Eviction simply drops the weights so the files can be removed.
extension MLXWhisperEngine: LocalModelResidencyReporting {
    public func residentModelDirectories() async -> Set<URL> {
        guard let directory = await backend.loadedModelDirectory() else { return [] }
        return [directory]
    }

    public func leaseCount(at directory: URL) async -> Int { 0 }

    public func requestEviction(at directory: URL) async -> Bool {
        let normalized = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard await backend.loadedModelDirectory()?.standardizedFileURL.resolvingSymlinksInPath() == normalized else {
            return true
        }
        await backend.unload()
        loadedModelName = nil
        return true
    }
}
