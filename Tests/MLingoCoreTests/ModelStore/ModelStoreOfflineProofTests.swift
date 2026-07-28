import Foundation
import Testing
@testable import MLingoCore

/// The claim "the default suite is offline" is otherwise indistinguishable from "the network was
/// fast". This exercises the whole lifecycle with a `URLProtocol` spy registered and asserts the
/// count is zero.
@Test
func theDefaultModelStoreSuiteMakesNoNetworkRequest() async throws {
    let temporary = try TemporaryDirectory(label: "OfflineProof")
    defer { temporary.remove() }
    let spy = ModelStoreNetworkSpy()
    spy.start()
    defer { spy.stop() }

    let layout = ModelStorageLayout(root: temporary.appending("Models", isDirectory: true))
    let entry = MLingoModelCatalog.whisperBase
    let manager = ModelManager(
        layout: layout,
        downloader: FakeModelSnapshotDownloader(root: layout.hubCacheRoot, outcomes: [.success()]),
        catalog: [entry],
        accounting: ModelStorageAccounting(layout: layout, availableBytes: { 1 << 40 }),
        progressThrottle: .zero
    )

    await manager.install(entry.id)
    #expect(await manager.state(for: entry.id) == .installed)
    _ = await manager.catalogSnapshot()
    let lease = try await manager.acquireLease(entry.id)
    await manager.releaseLease(lease)
    _ = await manager.installedDirectory(forModelID: entry.id.rawValue)
    try await manager.delete(entry.id)
    await manager.reconcile()

    #expect(spy.requestCount == 0, "the default suite reached the network \(spy.requestCount) times")
}

@Test
func verificationAndInstallationTouchNoNetwork() async throws {
    let temporary = try TemporaryDirectory(label: "OfflineProof")
    defer { temporary.remove() }
    let spy = ModelStoreNetworkSpy()
    spy.start()
    defer { spy.stop() }

    let layout = ModelStorageLayout(root: temporary.appending("Models", isDirectory: true))
    try layout.createBuckets()
    let entry = MLingoModelCatalog.qwen3Chat
    let staging = layout.staging(entry.slug, run: UUID())
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    for name in ["config.json", "tokenizer.json", "model.safetensors"] {
        let data = name.hasSuffix(".json") ? Data(#"{"a":1}"#.utf8) : Data(repeating: 0x42, count: 64)
        try data.write(to: staging.appending(path: name, directoryHint: .notDirectory))
    }

    try ModelSnapshotVerifier().verify(staging, against: entry)
    try ModelInstaller(layout: layout).install(staging: staging, into: layout.installed(entry.slug))

    #expect(spy.requestCount == 0)
}
