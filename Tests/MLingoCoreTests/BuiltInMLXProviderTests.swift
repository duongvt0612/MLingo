import Foundation
import Testing
@testable import MLingoCore

@Test
func builtInMLXTranslationMapsPromptAndNeverTouchesNetwork() async throws {
    NetworkSpyURLProtocol.reset()
    URLProtocol.registerClass(NetworkSpyURLProtocol.self)
    defer { URLProtocol.unregisterClass(NetworkSpyURLProtocol.self) }

    let modelDirectory = try makeTemporaryModelDirectory()
    let chat = FakeBuiltInChatRunner(chunks: [" Xin", " chao "])
    let runtime = BuiltInMLXRuntime(
        chatLoader: { _ in chat },
        embeddingLoader: { _ in FakeBuiltInEmbeddingRunner(vectors: []) },
        memorySampler: FixedLocalModelMemorySampler(availableBytes: 1_000_000),
        fileSizer: { _ in 64 },
        idleUnloadDelay: .milliseconds(50)
    )
    let provider = BuiltInMLXProvider(runtime: runtime)

    let item = try await provider.translate(
        TranslationProviderRequest(
            translation: TranslationRequest(
                current: Transcript(text: "  Hello  ", timestamp: 4),
                context: [Transcript(text: "Previous line", timestamp: 1)]
            ),
            model: modelDirectory.path,
            sourceLanguage: "English",
            targetLanguage: "Vietnamese"
        )
    )

    let messages = await chat.messages
    #expect(item.original == "Hello")
    #expect(item.translated == "Xin chao")
    #expect(item.start == 4)
    #expect(item.end == 7)
    #expect(messages.map(\.role) == [.system, .user])
    #expect(messages.first?.content.contains("Translate English subtitles into Vietnamese") == true)
    #expect(messages.last?.content.contains("Previous line") == true)
    #expect(messages.last?.content.contains("Hello") == true)
    #expect(NetworkSpyURLProtocol.requestCount == 0)
}

@Test
func builtInMLXChatStreamingCancellationReleasesLease() async throws {
    let modelDirectory = try makeTemporaryModelDirectory()
    let chat = BlockingBuiltInChatRunner(firstChunk: "Hel")
    let runtime = BuiltInMLXRuntime(
        chatLoader: { _ in chat },
        embeddingLoader: { _ in FakeBuiltInEmbeddingRunner(vectors: []) },
        memorySampler: FixedLocalModelMemorySampler(availableBytes: 1_000_000),
        fileSizer: { _ in 64 },
        idleUnloadDelay: .milliseconds(50)
    )
    let provider = BuiltInMLXProvider(runtime: runtime)
    let stream = provider.streamResponse(
        to: ChatRequest(
            messages: [ChatMessage(role: .user, content: "Hello")],
            model: modelDirectory.path
        )
    )

    let task = Task {
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    try await builtInEventually { await chat.started }
    try await builtInEventually { await runtime.activeLeaseCount == 1 }
    task.cancel()
    _ = try? await task.value

    try await builtInEventually { await runtime.activeLeaseCount == 0 }
    #expect(await chat.wasCancelled)
}

@Test
func builtInMLXEmbeddingsAreNormalizedDeterministicAndShapeStable() async throws {
    let modelDirectory = try makeTemporaryModelDirectory()
    let embedding = FakeBuiltInEmbeddingRunner(vectors: [
        [3, 4],
        [0, 2],
    ])
    let runtime = BuiltInMLXRuntime(
        chatLoader: { _ in FakeBuiltInChatRunner(chunks: []) },
        embeddingLoader: { _ in embedding },
        memorySampler: FixedLocalModelMemorySampler(availableBytes: 1_000_000),
        fileSizer: { _ in 64 },
        idleUnloadDelay: .milliseconds(50)
    )
    let provider = BuiltInMLXProvider(runtime: runtime)
    let request = EmbeddingRequest(inputs: ["hello", "xin chao"], model: modelDirectory.path)

    let first = try await provider.embed(request)
    let second = try await provider.embed(request)

    #expect(first == second)
    #expect(first.vectors.count == 2)
    #expect(first.vectors.allSatisfy { $0.count == 2 })
    #expect(abs(first.vectors[0][0] - 0.6) < 0.0001)
    #expect(abs(first.vectors[0][1] - 0.8) < 0.0001)
    #expect(abs(first.vectors[1][0] - 0.0) < 0.0001)
    #expect(abs(first.vectors[1][1] - 1.0) < 0.0001)
}

@Test
func builtInMLXRuntimeSharesLeasesAndUnloadsAfterIdleDelay() async throws {
    let modelDirectory = try makeTemporaryModelDirectory()
    let chat = BlockingBuiltInChatRunner(firstChunk: "ok")
    let loader = CountingBuiltInChatLoader(runner: chat)
    let runtime = BuiltInMLXRuntime(
        chatLoader: { url in try await loader.load(url) },
        embeddingLoader: { _ in FakeBuiltInEmbeddingRunner(vectors: []) },
        memorySampler: FixedLocalModelMemorySampler(availableBytes: 1_000_000),
        fileSizer: { _ in 64 },
        idleUnloadDelay: .milliseconds(20)
    )
    let provider = BuiltInMLXProvider(runtime: runtime)
    let request = ChatRequest(
        messages: [ChatMessage(role: .user, content: "Hello")],
        model: modelDirectory.path
    )

    let first = Task { try await provider.respond(to: request) }
    let second = Task { try await provider.respond(to: request) }

    try await builtInEventually { await runtime.activeLeaseCount == 2 }
    #expect(await loader.loadCount == 1)
    await chat.release()
    _ = try await first.value
    _ = try await second.value

    try await builtInEventually { await runtime.activeLeaseCount == 0 }
    try await builtInEventually { await runtime.loadedChatModelCount == 0 }
}

@Test
func builtInMLXRuntimeFailsPreflightBeforeLoadingOversizedModel() async throws {
    let modelDirectory = try makeTemporaryModelDirectory()
    let loader = CountingBuiltInChatLoader(runner: FakeBuiltInChatRunner(chunks: ["unused"]))
    let runtime = BuiltInMLXRuntime(
        chatLoader: { url in try await loader.load(url) },
        embeddingLoader: { _ in FakeBuiltInEmbeddingRunner(vectors: []) },
        memorySampler: FixedLocalModelMemorySampler(availableBytes: 50),
        fileSizer: { _ in 100 },
        idleUnloadDelay: .milliseconds(50)
    )
    let provider = BuiltInMLXProvider(runtime: runtime)

    await #expect(throws: MLingoError.insufficientLocalModelMemory(
        requiredBytes: 100,
        availableBytes: 50
    )) {
        _ = try await provider.respond(
            to: ChatRequest(
                messages: [ChatMessage(role: .user, content: "Hello")],
                model: modelDirectory.path
            )
        )
    }
    #expect(await loader.loadCount == 0)
}

@Test
func providerTranslationEngineRoutesBuiltInSelectionToNativeProvider() async throws {
    let modelDirectory = try makeTemporaryModelDirectory()
    let profile = OpenAICompatiblePresets.make(
        kind: .builtInMLX,
        name: "Built-in MLX",
        models: [.translation: [modelDirectory.path]]
    )
    let store = BuiltInProfileStore(configuration: ProviderConfiguration(
        profiles: [profile],
        selections: [
            .translation: CapabilitySelection(
                profileID: profile.id,
                model: modelDirectory.path
            ),
        ]
    ))
    let chat = FakeBuiltInChatRunner(chunks: ["xin chao"])
    let runtime = BuiltInMLXRuntime(
        chatLoader: { _ in chat },
        embeddingLoader: { _ in FakeBuiltInEmbeddingRunner(vectors: []) },
        memorySampler: FixedLocalModelMemorySampler(availableBytes: 1_000_000),
        fileSizer: { _ in 64 },
        idleUnloadDelay: .milliseconds(50)
    )
    let provider = BuiltInMLXProvider(runtime: runtime)
    let engine = ProviderTranslationEngine(
        profileStore: store,
        providerResolver: { selection in
            #expect(selection.profile.kind == .builtInMLX)
            return provider
        }
    )

    let result = try await engine.translate(
        TranslationRequest(current: Transcript(text: "hello", timestamp: 0)),
        settings: AppSettings(sourceLanguage: "English", targetLanguage: "Vietnamese")
    )

    #expect(result.translated == "xin chao")
}

private final class FakeBuiltInChatRunner: BuiltInMLXChatRunning, @unchecked Sendable {
    private let chunks: [String]
    private let state = FakeBuiltInChatRunnerState()
    var messages: [ChatMessage] {
        get async { await state.messages }
    }

    init(chunks: [String]) {
        self.chunks = chunks
    }

    func streamResponse(to messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        let chunks = chunks
        return AsyncThrowingStream { continuation in
            Task {
                await state.setMessages(messages)
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }
}

private actor FakeBuiltInChatRunnerState {
    private(set) var messages: [ChatMessage] = []

    func setMessages(_ messages: [ChatMessage]) {
        self.messages = messages
    }
}

private final class BlockingBuiltInChatRunner: BuiltInMLXChatRunning, @unchecked Sendable {
    private let firstChunk: String
    private let state = BlockingBuiltInChatRunnerState()
    var started: Bool {
        get async { await state.started }
    }
    var wasCancelled: Bool {
        get async { await state.wasCancelled }
    }

    init(firstChunk: String) {
        self.firstChunk = firstChunk
    }

    func streamResponse(to messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        let firstChunk = firstChunk
        return AsyncThrowingStream { continuation in
            let task = Task {
                await state.markStarted()
                continuation.yield(firstChunk)
                await state.waitForRelease()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.state.markCancelledAndRelease() }
            }
        }
    }

    func release() async {
        await state.release()
    }
}

private actor BlockingBuiltInChatRunnerState {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var started = false
    private(set) var wasCancelled = false

    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func markStarted() {
        started = true
    }

    func markCancelledAndRelease() {
        wasCancelled = true
        release()
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }
}

private actor FakeBuiltInEmbeddingRunner: BuiltInMLXEmbeddingRunning {
    private let vectors: [[Float]]

    init(vectors: [[Float]]) {
        self.vectors = vectors
    }

    func embed(_ inputs: [String]) async throws -> [[Float]] {
        Array(vectors.prefix(inputs.count))
    }
}

private actor CountingBuiltInChatLoader {
    private let runner: any BuiltInMLXChatRunning
    private(set) var loadCount = 0

    init(runner: any BuiltInMLXChatRunning) {
        self.runner = runner
    }

    func load(_ url: URL) async throws -> any BuiltInMLXChatRunning {
        loadCount += 1
        return runner
    }
}

private struct FixedLocalModelMemorySampler: LocalModelMemorySampling {
    let availableBytes: UInt64

    func availableMemoryBytes() async -> UInt64 {
        availableBytes
    }
}

private actor BuiltInProfileStore: ProviderProfileStoreProtocol {
    private let configuration: ProviderConfiguration

    init(configuration: ProviderConfiguration) {
        self.configuration = configuration
    }

    func load() async throws -> ProviderConfiguration {
        configuration
    }

    func save(_ configuration: ProviderConfiguration) async throws {}
}

private final class NetworkSpyURLProtocol: URLProtocol, @unchecked Sendable {
    private static let counter = NetworkSpyCounter()
    static var requestCount: Int { counter.value }

    static func reset() {
        counter.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        counter.increment()
        return false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {}
    override func stopLoading() {}
}

private final class NetworkSpyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0
    var value: Int { lock.withLock { storedValue } }

    func increment() {
        lock.withLock { storedValue += 1 }
    }

    func reset() {
        lock.withLock { storedValue = 0 }
    }
}

private func makeTemporaryModelDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "MLingo-BuiltInMLX-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func builtInEventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition was not met before timeout")
}
