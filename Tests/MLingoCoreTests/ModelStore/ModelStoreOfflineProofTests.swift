import Foundation
import Testing
@testable import MLingoCore

/// Every test that installs `ModelStoreNetworkSpy` lives here, and the suite is serialized.
///
/// The spy registers a `URLProtocol` subclass process-wide and counts through shared state, so two
/// of these running at once would each see the other's traffic and could unregister the class from
/// under one another. Serialising the suite is what makes the counts mean anything; keeping every
/// spy user in this one suite is what makes the serialisation sufficient, since `.serialized`
/// orders tests within a suite and not across them.
@Suite(.serialized)
struct ModelStoreOfflineProofTests {
    /// The claim "the default suite is offline" is otherwise indistinguishable from "the network
    /// was fast". This exercises the whole lifecycle with the spy registered.
    ///
    /// The spy sees requests made through `URLSession` on the default configuration, which is the
    /// only way this code reaches the network. A session built with its own `protocolClasses`, or
    /// a raw socket, would not be observed.
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

        _ = try ModelSnapshotVerifier().verify(staging, against: entry)
        try ModelInstaller(layout: layout).install(staging: staging, into: layout.installed(entry.slug))

        #expect(spy.requestCount == 0)
    }

    @Test
    func hubDownloaderRejectsAMalformedRepositoryWithoutMakingARequest() async throws {
        let temporary = try TemporaryDirectory(label: "HubDownloader")
        defer { temporary.remove() }
        let spy = ModelStoreNetworkSpy()
        spy.start()
        defer { spy.stop() }

        let downloader = HubModelSnapshotDownloader(cacheDirectory: temporary.url)
        let request = ModelDownloadRequest(
            repository: "no-slash",
            revision: String(repeating: "a", count: 40),
            files: ["config.json"]
        )

        await #expect(throws: ModelStoreError(issue: .repositoryNotFound(repository: "no-slash"))) {
            _ = try await downloader.downloadSnapshot(request, token: nil) { _ in }
        }
        #expect(spy.requestCount == 0)
    }
}
