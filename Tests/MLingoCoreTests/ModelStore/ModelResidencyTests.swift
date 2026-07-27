import Foundation
import Testing
@testable import MLingoCore

private let residencyModelID = ModelID("owner/resident")

private func makeResidencyEntry() throws -> ModelCatalogEntry {
    ModelCatalogEntry(
        id: residencyModelID,
        slug: try #require(ModelStorageSlug("resident")),
        role: .chat,
        repository: "owner/resident",
        revision: String(repeating: "f", count: 40),
        files: ["config.json", "tokenizer.json", "model.safetensors"],
        requiredFiles: ["config.json", "tokenizer.json", "model.safetensors"],
        expectedBytes: 1_000
    )
}

// MARK: - BuiltInMLXRuntime conformance

@Test
func runtimeReportsLoadedModelsAsResident() async throws {
    let directory = try TemporaryDirectory(label: "Residency")
    defer { directory.remove() }
    let runtime = BuiltInMLXRuntime(
        chatLoader: { _ in ResidencyChatRunner() },
        idleUnloadDelay: .seconds(60)
    )

    _ = try await runtime.respond(model: directory.url.path, messages: [ChatMessage(role: .user, content: "hi")])

    let resident = await runtime.residentModelDirectories()
    #expect(resident.contains(directory.url.resolvingSymlinksInPath().standardizedFileURL))
    // The lease is released once the reply is complete, but the weights stay resident until the
    // idle timer fires — which is exactly the window a delete has to survive.
    #expect(await runtime.leaseCount(at: directory.url) == 0)
}

@Test
func runtimeEvictsAnIdleModelOnRequest() async throws {
    let directory = try TemporaryDirectory(label: "Residency")
    defer { directory.remove() }
    let runtime = BuiltInMLXRuntime(
        chatLoader: { _ in ResidencyChatRunner() },
        idleUnloadDelay: .seconds(600)
    )
    _ = try await runtime.respond(model: directory.url.path, messages: [ChatMessage(role: .user, content: "hi")])
    #expect(await runtime.loadedChatModelCount == 1)

    #expect(await runtime.requestEviction(at: directory.url))

    #expect(await runtime.loadedChatModelCount == 0)
    #expect(await runtime.residentModelDirectories().isEmpty)
}

@Test
func runtimeRefusesEvictionWhileAModelIsLeased() async throws {
    let directory = try TemporaryDirectory(label: "Residency")
    defer { directory.remove() }
    let gate = ResidencyGate()
    let runtime = BuiltInMLXRuntime(chatLoader: { _ in ResidencyChatRunner(gate: gate) })

    let streaming = Task {
        _ = try await runtime.respond(
            model: directory.url.path,
            messages: [ChatMessage(role: .user, content: "hi")]
        )
    }
    try await eventually { await gate.isBlocked }

    #expect(await runtime.leaseCount(at: directory.url) == 1)
    #expect(await runtime.requestEviction(at: directory.url) == false)
    #expect(await runtime.loadedChatModelCount == 1)

    await gate.release()
    _ = try await streaming.value
}

@Test
func runtimeReportsNothingForAnUnknownDirectory() async throws {
    let runtime = BuiltInMLXRuntime(chatLoader: { _ in ResidencyChatRunner() })
    #expect(await runtime.leaseCount(at: URL(fileURLWithPath: "/tmp/never-loaded")) == 0)
    #expect(await runtime.requestEviction(at: URL(fileURLWithPath: "/tmp/never-loaded")))
}

// MARK: - Deletion guard

@Test
func deleteIsRefusedWhileTheRuntimeStillHoldsTheModel() async throws {
    let temporary = try TemporaryDirectory(label: "Residency")
    defer { temporary.remove() }
    let layout = ModelStorageLayout(root: temporary.appending("Models", isDirectory: true))
    let residency = StubResidency(evictionSucceeds: false)
    let manager = ModelManager(
        layout: layout,
        downloader: FakeModelSnapshotDownloader(root: layout.hubCacheRoot, outcomes: [.success()]),
        catalog: [try makeResidencyEntry()],
        accounting: ModelStorageAccounting(layout: layout, availableBytes: { 1 << 40 }),
        residency: residency,
        progressThrottle: .zero
    )
    await manager.install(residencyModelID)

    await #expect(throws: ModelStoreError(issue: .modelInUse(residencyModelID))) {
        try await manager.delete(residencyModelID)
    }
    #expect(await manager.installedDirectory(for: residencyModelID) != nil)
    #expect(await residency.evictionRequests == 1)
}

@Test
func deleteProceedsOnceTheRuntimeReleasesTheModel() async throws {
    let temporary = try TemporaryDirectory(label: "Residency")
    defer { temporary.remove() }
    let layout = ModelStorageLayout(root: temporary.appending("Models", isDirectory: true))
    let residency = StubResidency(evictionSucceeds: true)
    let manager = ModelManager(
        layout: layout,
        downloader: FakeModelSnapshotDownloader(root: layout.hubCacheRoot, outcomes: [.success()]),
        catalog: [try makeResidencyEntry()],
        accounting: ModelStorageAccounting(layout: layout, availableBytes: { 1 << 40 }),
        residency: residency,
        progressThrottle: .zero
    )
    await manager.install(residencyModelID)

    try await manager.delete(residencyModelID)

    #expect(await manager.state(for: residencyModelID) == .notInstalled)
    #expect(await residency.evictionRequests == 1)
    #expect(await residency.lastRequestedDirectory?.lastPathComponent == "resident")
}

@Test
func deleteAsksTheLeaseRegistryBeforeTheRuntime() async throws {
    let temporary = try TemporaryDirectory(label: "Residency")
    defer { temporary.remove() }
    let layout = ModelStorageLayout(root: temporary.appending("Models", isDirectory: true))
    let residency = StubResidency(evictionSucceeds: true)
    let manager = ModelManager(
        layout: layout,
        downloader: FakeModelSnapshotDownloader(root: layout.hubCacheRoot, outcomes: [.success()]),
        catalog: [try makeResidencyEntry()],
        accounting: ModelStorageAccounting(layout: layout, availableBytes: { 1 << 40 }),
        residency: residency,
        progressThrottle: .zero
    )
    await manager.install(residencyModelID)
    let lease = try await manager.acquireLease(residencyModelID)

    await #expect(throws: ModelStoreError(issue: .modelInUse(residencyModelID))) {
        try await manager.delete(residencyModelID)
    }
    // A held lease is refused outright; there is no point asking the runtime to evict a model
    // someone is about to use.
    #expect(await residency.evictionRequests == 0)

    await manager.releaseLease(lease)
    try await manager.delete(residencyModelID)
}

// MARK: - Doubles

private actor StubResidency: LocalModelResidencyReporting {
    private let evictionSucceeds: Bool
    private(set) var evictionRequests = 0
    private(set) var lastRequestedDirectory: URL?

    init(evictionSucceeds: Bool) {
        self.evictionSucceeds = evictionSucceeds
    }

    func residentModelDirectories() -> Set<URL> { lastRequestedDirectory.map { [$0] } ?? [] }

    func leaseCount(at directory: URL) -> Int { evictionSucceeds ? 0 : 1 }

    func requestEviction(at directory: URL) -> Bool {
        evictionRequests += 1
        lastRequestedDirectory = directory
        return evictionSucceeds
    }
}

private final class ResidencyChatRunner: BuiltInMLXChatRunning, @unchecked Sendable {
    private let gate: ResidencyGate?

    init(gate: ResidencyGate? = nil) {
        self.gate = gate
    }

    func streamResponse(to messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [gate] in
                if let gate {
                    await gate.block()
                }
                continuation.yield("ok")
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor ResidencyGate {
    private var blocked = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    var isBlocked: Bool { blocked }

    func block() async {
        guard !released else { return }
        blocked = true
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                waiter = continuation
            }
        }
    }

    func release() {
        released = true
        blocked = false
        waiter?.resume()
        waiter = nil
    }
}
