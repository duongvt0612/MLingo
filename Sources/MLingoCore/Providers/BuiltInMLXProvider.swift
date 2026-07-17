import Foundation
import HuggingFace
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

protocol BuiltInMLXChatRunning: AnyObject, Sendable {
    func streamResponse(to messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
}

protocol BuiltInMLXEmbeddingRunning: AnyObject, Sendable {
    func embed(_ inputs: [String]) async throws -> [[Float]]
}

protocol LocalModelMemorySampling: Sendable {
    func availableMemoryBytes() async -> UInt64
}

typealias BuiltInMLXChatLoader = @Sendable (URL) async throws -> any BuiltInMLXChatRunning
typealias BuiltInMLXEmbeddingLoader = @Sendable (URL) async throws -> any BuiltInMLXEmbeddingRunning
typealias BuiltInMLXFileSizer = @Sendable (URL) throws -> UInt64

public final class BuiltInMLXProvider: TranslationProvider,
    ChatStreamingProvider,
    EmbeddingProvider,
    @unchecked Sendable
{
    private let runtime: BuiltInMLXRuntime

    public convenience init() {
        self.init(runtime: BuiltInMLXRuntime())
    }

    init(runtime: BuiltInMLXRuntime) {
        self.runtime = runtime
    }

    public func translate(_ request: TranslationProviderRequest) async throws -> SubtitleItem {
        let currentText = request.translation.current.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentText.isEmpty else {
            throw MLingoError.invalidTranslationConfiguration("Transcript text is empty.")
        }
        guard !request.sourceLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MLingoError.invalidTranslationConfiguration("Add a source language in Settings.")
        }
        guard !request.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MLingoError.invalidTranslationConfiguration("Add a target language in Settings.")
        }

        let settings = AppSettings(
            openAIModel: request.model,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage
        )
        let contextTexts = request.translation.context.map {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let response = try await runtime.respond(
            model: request.model,
            messages: [
                ChatMessage(
                    role: .system,
                    content: TranslationPromptBuilder.instructions(settings: settings)
                ),
                ChatMessage(
                    role: .user,
                    content: TranslationPromptBuilder.input(
                        currentText: currentText,
                        contextTexts: contextTexts
                    )
                ),
            ]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return SubtitleItem(
            original: currentText,
            translated: response,
            start: request.translation.current.timestamp,
            end: request.translation.current.timestamp + 3
        )
    }

    public func respond(to request: ChatRequest) async throws -> ChatResponse {
        let text = try await runtime.respond(model: request.model, messages: request.messages)
        return ChatResponse(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func streamResponse(to request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        runtime.streamChat(model: request.model, messages: request.messages)
    }

    public func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResponse {
        let vectors = try await runtime.embed(model: request.model, inputs: request.inputs)
        return EmbeddingResponse(vectors: vectors)
    }
}

actor BuiltInMLXRuntime {
    private struct LoadedChatModel {
        let runner: any BuiltInMLXChatRunning
        var activeLeases: Int
        var unloadTask: Task<Void, Never>?
    }

    private struct LoadedEmbeddingModel {
        let runner: any BuiltInMLXEmbeddingRunning
        var activeLeases: Int
        var unloadTask: Task<Void, Never>?
    }

    private let chatLoader: BuiltInMLXChatLoader
    private let embeddingLoader: BuiltInMLXEmbeddingLoader
    private let memorySampler: any LocalModelMemorySampling
    private let fileSizer: BuiltInMLXFileSizer
    private let idleUnloadDelay: Duration
    private let fileManager: FileManager

    private var loadedChatModels: [URL: LoadedChatModel] = [:]
    private var loadingChatModels: [URL: Task<any BuiltInMLXChatRunning, Error>] = [:]
    private var loadedEmbeddingModels: [URL: LoadedEmbeddingModel] = [:]
    private var loadingEmbeddingModels: [URL: Task<any BuiltInMLXEmbeddingRunning, Error>] = [:]

    var activeLeaseCount: Int {
        loadedChatModels.values.reduce(0) { $0 + $1.activeLeases }
            + loadedEmbeddingModels.values.reduce(0) { $0 + $1.activeLeases }
    }

    var loadedChatModelCount: Int {
        loadedChatModels.count
    }

    init(
        chatLoader: @escaping BuiltInMLXChatLoader = { url in
            try await DefaultBuiltInMLXChatRunner(modelDirectory: url)
        },
        embeddingLoader: @escaping BuiltInMLXEmbeddingLoader = { url in
            try await DefaultBuiltInMLXEmbeddingRunner(modelDirectory: url)
        },
        memorySampler: any LocalModelMemorySampling = DefaultLocalModelMemorySampler(),
        fileSizer: @escaping BuiltInMLXFileSizer = DirectoryLocalModelFileSizer.size,
        idleUnloadDelay: Duration = .seconds(60),
        fileManager: FileManager = .default
    ) {
        self.chatLoader = chatLoader
        self.embeddingLoader = embeddingLoader
        self.memorySampler = memorySampler
        self.fileSizer = fileSizer
        self.idleUnloadDelay = idleUnloadDelay
        self.fileManager = fileManager
    }

    func respond(model: String, messages: [ChatMessage]) async throws -> String {
        var response = ""
        for try await chunk in streamChat(model: model, messages: messages) {
            response += chunk
        }
        return response
    }

    nonisolated func streamChat(
        model: String,
        messages: [ChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runChatStream(
                    model: model,
                    messages: messages,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        guard !inputs.isEmpty else { return [] }
        let directory = try modelDirectory(from: model)
        let runner: any BuiltInMLXEmbeddingRunning
        do {
            runner = try await acquireEmbeddingModel(at: directory)
        } catch {
            throw mapLoadError(error, model: model)
        }
        do {
            let vectors = try await runner.embed(inputs)
            releaseEmbeddingModel(at: directory)
            return Self.normalize(vectors)
        } catch is CancellationError {
            releaseEmbeddingModel(at: directory)
            throw CancellationError()
        } catch {
            releaseEmbeddingModel(at: directory)
            throw MLingoError.localModelLoadFailed(error.localizedDescription)
        }
    }

    private func runChatStream(
        model: String,
        messages: [ChatMessage],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        let directory: URL
        do {
            directory = try modelDirectory(from: model)
        } catch {
            continuation.finish(throwing: error)
            return
        }

        let runner: any BuiltInMLXChatRunning
        do {
            runner = try await acquireChatModel(at: directory)
        } catch {
            continuation.finish(throwing: mapLoadError(error, model: model))
            return
        }

        do {
            for try await chunk in runner.streamResponse(to: messages) {
                try Task.checkCancellation()
                continuation.yield(chunk)
            }
            releaseChatModel(at: directory)
            continuation.finish()
        } catch is CancellationError {
            releaseChatModel(at: directory)
            continuation.finish(throwing: CancellationError())
        } catch {
            releaseChatModel(at: directory)
            continuation.finish(throwing: MLingoError.localModelLoadFailed(error.localizedDescription))
        }
    }

    private func acquireChatModel(at directory: URL) async throws -> any BuiltInMLXChatRunning {
        if var loaded = loadedChatModels[directory] {
            loaded.unloadTask?.cancel()
            loaded.unloadTask = nil
            loaded.activeLeases += 1
            loadedChatModels[directory] = loaded
            return loaded.runner
        }

        let task: Task<any BuiltInMLXChatRunning, Error>
        if let existing = loadingChatModels[directory] {
            task = existing
        } else {
            try await preflight(directory)
            task = Task { try await chatLoader(directory) }
            loadingChatModels[directory] = task
        }

        do {
            let runner = try await task.value
            loadingChatModels[directory] = nil
            if var loaded = loadedChatModels[directory] {
                loaded.unloadTask?.cancel()
                loaded.unloadTask = nil
                loaded.activeLeases += 1
                loadedChatModels[directory] = loaded
            } else {
                loadedChatModels[directory] = LoadedChatModel(
                    runner: runner,
                    activeLeases: 1,
                    unloadTask: nil
                )
            }
            return runner
        } catch {
            loadingChatModels[directory] = nil
            throw error
        }
    }

    private func acquireEmbeddingModel(
        at directory: URL
    ) async throws -> any BuiltInMLXEmbeddingRunning {
        if var loaded = loadedEmbeddingModels[directory] {
            loaded.unloadTask?.cancel()
            loaded.unloadTask = nil
            loaded.activeLeases += 1
            loadedEmbeddingModels[directory] = loaded
            return loaded.runner
        }

        let task: Task<any BuiltInMLXEmbeddingRunning, Error>
        if let existing = loadingEmbeddingModels[directory] {
            task = existing
        } else {
            try await preflight(directory)
            task = Task { try await embeddingLoader(directory) }
            loadingEmbeddingModels[directory] = task
        }

        do {
            let runner = try await task.value
            loadingEmbeddingModels[directory] = nil
            if var loaded = loadedEmbeddingModels[directory] {
                loaded.unloadTask?.cancel()
                loaded.unloadTask = nil
                loaded.activeLeases += 1
                loadedEmbeddingModels[directory] = loaded
            } else {
                loadedEmbeddingModels[directory] = LoadedEmbeddingModel(
                    runner: runner,
                    activeLeases: 1,
                    unloadTask: nil
                )
            }
            return runner
        } catch {
            loadingEmbeddingModels[directory] = nil
            throw error
        }
    }

    private func releaseChatModel(at directory: URL) {
        guard var loaded = loadedChatModels[directory] else { return }
        loaded.activeLeases = max(0, loaded.activeLeases - 1)
        guard loaded.activeLeases == 0 else {
            loadedChatModels[directory] = loaded
            return
        }
        loaded.unloadTask?.cancel()
        loaded.unloadTask = Task { [idleUnloadDelay] in
            do {
                try await Task.sleep(for: idleUnloadDelay)
                self.unloadChatModelIfIdle(at: directory)
            } catch {}
        }
        loadedChatModels[directory] = loaded
    }

    private func releaseEmbeddingModel(at directory: URL) {
        guard var loaded = loadedEmbeddingModels[directory] else { return }
        loaded.activeLeases = max(0, loaded.activeLeases - 1)
        guard loaded.activeLeases == 0 else {
            loadedEmbeddingModels[directory] = loaded
            return
        }
        loaded.unloadTask?.cancel()
        loaded.unloadTask = Task { [idleUnloadDelay] in
            do {
                try await Task.sleep(for: idleUnloadDelay)
                self.unloadEmbeddingModelIfIdle(at: directory)
            } catch {}
        }
        loadedEmbeddingModels[directory] = loaded
    }

    private func unloadChatModelIfIdle(at directory: URL) {
        guard let loaded = loadedChatModels[directory], loaded.activeLeases == 0 else { return }
        loaded.unloadTask?.cancel()
        loadedChatModels[directory] = nil
    }

    private func unloadEmbeddingModelIfIdle(at directory: URL) {
        guard let loaded = loadedEmbeddingModels[directory], loaded.activeLeases == 0 else {
            return
        }
        loaded.unloadTask?.cancel()
        loadedEmbeddingModels[directory] = nil
    }

    private func preflight(_ directory: URL) async throws {
        let requiredBytes = try fileSizer(directory)
        let availableBytes = await memorySampler.availableMemoryBytes()
        guard requiredBytes <= availableBytes else {
            throw MLingoError.insufficientLocalModelMemory(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )
        }
    }

    private func modelDirectory(from value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MLingoError.localModelUnavailable("Choose an installed local MLX model.")
        }

        let directory: URL
        if let url = URL(string: trimmed), let scheme = url.scheme {
            guard scheme == "file", url.isFileURL else {
                throw MLingoError.localModelUnavailable(
                    "Built-in MLX models must use an installed local path or file URL."
                )
            }
            directory = url
        } else {
            directory = URL(fileURLWithPath: trimmed, isDirectory: true)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw MLingoError.localModelUnavailable(
                "The selected local MLX model directory does not exist."
            )
        }
        return directory.standardizedFileURL
    }

    private func mapLoadError(_ error: any Error, model: String) -> MLingoError {
        if let error = error as? MLingoError { return error }
        return .localModelLoadFailed(
            "Could not load local MLX model \(model). \(error.localizedDescription)"
        )
    }

    private static func normalize(_ vectors: [[Float]]) -> [[Float]] {
        vectors.map { vector in
            let norm = sqrt(vector.reduce(Double(0)) { partial, value in
                partial + Double(value * value)
            })
            guard norm > 0 else { return vector }
            return vector.map { Float(Double($0) / norm) }
        }
    }
}

private final class DefaultBuiltInMLXChatRunner: BuiltInMLXChatRunning,
    @unchecked Sendable
{
    private let session: ChatSession

    init(modelDirectory: URL) async throws {
        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
            session = ChatSession(
                container,
                generateParameters: GenerateParameters(maxTokens: 512, temperature: 0)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MLingoError.localModelLoadFailed(error.localizedDescription)
        }
    }

    func streamResponse(to messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        session.streamResponse(to: messages.map(Self.message(from:)))
    }

    private static func message(from message: ChatMessage) -> Chat.Message {
        switch message.role {
        case .system:
            .system(message.content)
        case .user:
            .user(message.content)
        case .assistant:
            .assistant(message.content)
        }
    }
}

private final class DefaultBuiltInMLXEmbeddingRunner: BuiltInMLXEmbeddingRunning,
    @unchecked Sendable
{
    private let container: EmbedderModelContainer

    init(modelDirectory: URL) async throws {
        do {
            container = try await EmbedderModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MLingoError.localModelLoadFailed(error.localizedDescription)
        }
    }

    func embed(_ inputs: [String]) async throws -> [[Float]] {
        await container.perform { context in
            let tokenizer = context.tokenizer
            let encoded = inputs.map {
                tokenizer.encode(text: $0, addSpecialTokens: true)
            }
            let maxLength = encoded.reduce(into: 1) { current, tokens in
                current = max(current, tokens.count)
            }
            let paddingToken = tokenizer.eosTokenId ?? 0
            let padded = stacked(
                encoded.map { tokens in
                    MLXArray(
                        tokens + Array(
                            repeating: paddingToken,
                            count: maxLength - tokens.count
                        )
                    )
                }
            )
            let mask = padded .!= paddingToken
            let tokenTypes = MLXArray.zeros(like: padded)
            let output = context.model(
                padded,
                positionIds: nil,
                tokenTypeIds: tokenTypes,
                attentionMask: mask
            )
            let result = context.pooling(output, normalize: true, applyLayerNorm: true)
            result.eval()
            return result.map { $0.asArray(Float.self) }
        }
    }
}

private struct DefaultLocalModelMemorySampler: LocalModelMemorySampling {
    func availableMemoryBytes() async -> UInt64 {
        let physical = ProcessInfo.processInfo.physicalMemory
        guard let sample = await DarwinProcessMetricsSampler().sample() else {
            return physical
        }
        return physical > sample.residentMemoryBytes
            ? physical - sample.residentMemoryBytes
            : 0
    }
}

private enum DirectoryLocalModelFileSizer {
    static func size(_ directory: URL) throws -> UInt64 {
        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            throw MLingoError.localModelUnavailable(
                "Could not inspect the selected local MLX model directory."
            )
        }

        var total: UInt64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(resourceKeys))
            guard values.isRegularFile == true else { continue }
            let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            total += UInt64(max(allocated, 0))
        }
        return total
    }
}
