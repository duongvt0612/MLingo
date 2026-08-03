import Foundation
import Testing
@testable import MLingoCore

private let facadeModelID = ModelID("owner/facade")

private func makeFacadeEntry() throws -> ModelCatalogEntry {
    ModelCatalogEntry(
        id: facadeModelID,
        slug: try #require(ModelStorageSlug("facade")),
        role: .chat,
        repository: "owner/facade",
        revision: String(repeating: "a", count: 40),
        files: ["config.json", "tokenizer.json", "model.safetensors"],
        requiredFiles: ["config.json", "tokenizer.json", "model.safetensors"],
        expectedBytes: 1_000
    )
}

private func makeFacadeManager(root: URL) throws -> ModelManager {
    let layout = ModelStorageLayout(root: root)
    return ModelManager(
        layout: layout,
        downloader: FakeModelSnapshotDownloader(root: layout.hubCacheRoot, outcomes: [.success()]),
        catalog: [try makeFacadeEntry()],
        accounting: ModelStorageAccounting(layout: layout, availableBytes: { 1 << 40 }),
        progressThrottle: .zero
    )
}

@Test
func catalogFacadeExposesTheWholeLifecycleTheModelsPaneNeeds() async throws {
    let temporary = try TemporaryDirectory(label: "CatalogFacade")
    defer { temporary.remove() }
    // Settings only ever sees the protocol, so the test drives the manager through it: anything
    // missing here is something the pane could not do.
    let facade: any ModelCatalogManaging = try makeFacadeManager(
        root: temporary.appending("Models", isDirectory: true)
    )

    let before = await facade.catalogSnapshot()
    #expect(before.entries.map(\.state) == [.notInstalled])

    await facade.install(facadeModelID)

    let after = await facade.catalogSnapshot()
    #expect(after.entries.map(\.state) == [.installed])
    #expect(after.entries[0].installedBytes ?? 0 > 0)
    #expect(after.usage.installedBytes > 0)

    try await facade.delete(facadeModelID)
    #expect(await facade.catalogSnapshot().entries.map(\.state) == [.notInstalled])
}

@Test
func catalogFacadeStreamsStateChanges() async throws {
    let temporary = try TemporaryDirectory(label: "CatalogFacade")
    defer { temporary.remove() }
    let facade: any ModelCatalogManaging = try makeFacadeManager(
        root: temporary.appending("Models", isDirectory: true)
    )

    let stream = await facade.stateStream()
    await facade.install(facadeModelID)

    var sawInstalled = false
    for await snapshot in stream where snapshot.state(for: facadeModelID) == .installed {
        sawInstalled = true
        break
    }
    #expect(sawInstalled)
}

@Test
func catalogFacadeCancelsAnInFlightDownload() async throws {
    let temporary = try TemporaryDirectory(label: "CatalogFacade")
    defer { temporary.remove() }
    let layout = ModelStorageLayout(root: temporary.appending("Models", isDirectory: true))
    let manager = ModelManager(
        layout: layout,
        downloader: FakeModelSnapshotDownloader(
            root: layout.hubCacheRoot,
            outcomes: [.blockUntilCancelled, .success()]
        ),
        catalog: [try makeFacadeEntry()],
        accounting: ModelStorageAccounting(layout: layout, availableBytes: { 1 << 40 }),
        progressThrottle: .zero
    )
    let facade: any ModelCatalogManaging = manager

    let install = Task { await facade.install(facadeModelID) }
    try await eventually { await manager.state(for: facadeModelID).isBusy }
    await facade.cancel(facadeModelID)
    await install.value

    #expect(await manager.state(for: facadeModelID) == .cancelled)

    // Retry clears the cancelled state and installs from a fresh attempt.
    await facade.retry(facadeModelID)
    #expect(await manager.state(for: facadeModelID) == .installed)
}
