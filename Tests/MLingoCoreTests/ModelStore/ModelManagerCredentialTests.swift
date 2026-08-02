import Foundation
import Testing
@testable import MLingoCore

private let credentialModelID = ModelID("owner/gated")

private func makeGatedEntry() throws -> ModelCatalogEntry {
    ModelCatalogEntry(
        id: credentialModelID,
        slug: try #require(ModelStorageSlug("gated")),
        role: .chat,
        repository: "owner/gated",
        revision: String(repeating: "e", count: 40),
        files: ["config.json", "tokenizer.json", "model.safetensors"],
        requiredFiles: ["config.json", "tokenizer.json", "model.safetensors"],
        expectedBytes: 1_000
    )
}

private struct CredentialHarness {
    let temporary: TemporaryDirectory
    let layout: ModelStorageLayout
    let downloader: FakeModelSnapshotDownloader
    let keychain: ModelStoreKeychainClient
    let manager: ModelManager

    init(outcomes: [FakeModelSnapshotDownloader.Outcome], storedToken: String? = nil) throws {
        temporary = try TemporaryDirectory(label: "Credential")
        layout = ModelStorageLayout(root: temporary.appending("Models", isDirectory: true))
        downloader = FakeModelSnapshotDownloader(root: layout.hubCacheRoot, outcomes: outcomes)
        keychain = ModelStoreKeychainClient()
        let store = KeychainProviderCredentialStore(service: "test.models", client: keychain)
        if let storedToken {
            try store.saveCredential(storedToken, for: ModelManager.huggingFaceCredentialID)
        }
        manager = ModelManager(
            layout: layout,
            downloader: downloader,
            catalog: [try makeGatedEntry()],
            credentialStore: store,
            accounting: ModelStorageAccounting(layout: layout, availableBytes: { 1 << 40 }),
            progressThrottle: .zero
        )
    }

    func remove() { temporary.remove() }
}

@Test
func downloaderReceivesTheHuggingFaceTokenFromTheCredentialStore() async throws {
    let harness = try CredentialHarness(outcomes: [.success()], storedToken: "hf_stored")
    defer { harness.remove() }

    await harness.manager.install(credentialModelID)

    #expect(harness.downloader.tokens == ["hf_stored"])
    #expect(await harness.manager.state(for: credentialModelID) == .installed)
}

@Test
func downloaderReceivesNoTokenWhenNoneIsStored() async throws {
    let harness = try CredentialHarness(outcomes: [.success()])
    defer { harness.remove() }

    await harness.manager.install(credentialModelID)

    // Never a token picked up from the environment: HubClient's default provider would read
    // ~/.cache/huggingface/token and make results depend on the machine running the tests.
    #expect(harness.downloader.tokens == [nil])
}

@Test
func unauthorizedDownloadAsksForAHuggingFaceToken() async throws {
    let harness = try CredentialHarness(
        outcomes: [.failure(ModelStoreError(issue: .authenticationRequired))]
    )
    defer { harness.remove() }

    await harness.manager.install(credentialModelID)

    let state = await harness.manager.state(for: credentialModelID)
    #expect(state == .failed(ModelStoreError(issue: .authenticationRequired)))
    #expect(state.error?.recoveryAction == .addHuggingFaceToken)
}

@Test
func gatedRepositoryAsksTheUserToAcceptTheLicence() async throws {
    let harness = try CredentialHarness(
        outcomes: [.failure(ModelStoreError(issue: .accessGated(repository: "owner/gated")))],
        storedToken: "hf_stored"
    )
    defer { harness.remove() }

    await harness.manager.install(credentialModelID)

    let state = await harness.manager.state(for: credentialModelID)
    #expect(state.error?.recoveryAction == .acceptRepositoryLicence(repository: "owner/gated"))
    // A licence problem is not a corrupt download, so nothing is quarantined.
    let quarantined = try FileManager.default.contentsOfDirectory(atPath: harness.layout.quarantineRoot.path)
    #expect(quarantined.isEmpty)
}

@Test
func aCredentialStoreFailureLeavesTheDownloadUnauthenticatedRatherThanBroken() async throws {
    let harness = try CredentialHarness(outcomes: [.success()])
    defer { harness.remove() }
    harness.keychain.failReads = true

    await harness.manager.install(credentialModelID)

    // A Keychain that will not answer must not block a public model.
    #expect(harness.downloader.tokens == [nil])
    #expect(await harness.manager.state(for: credentialModelID) == .installed)
}

@Test
func theTokenNeverReachesTheReceiptIndex() async throws {
    let harness = try CredentialHarness(outcomes: [.success()], storedToken: "hf_supersecret")
    defer { harness.remove() }

    await harness.manager.install(credentialModelID)

    let receipts = try Data(contentsOf: harness.layout.receiptFile)
    let text = try #require(String(data: receipts, encoding: .utf8))
    #expect(!text.contains("hf_supersecret"))
    #expect(!text.contains("token"))
}

@Test
func theTokenIsReadFreshForEachDownloadRatherThanCached() async throws {
    let harness = try CredentialHarness(
        outcomes: [.failure(ModelStoreError(issue: .transportFailure)), .success()],
        storedToken: "hf_first"
    )
    defer { harness.remove() }
    await harness.manager.install(credentialModelID)

    let store = KeychainProviderCredentialStore(service: "test.models", client: harness.keychain)
    try store.saveCredential("hf_second", for: ModelManager.huggingFaceCredentialID)
    await harness.manager.retry(credentialModelID)

    // Holding the secret in actor state would keep it in memory for the life of the app and
    // would miss a token the user just corrected.
    #expect(harness.downloader.tokens == ["hf_first", "hf_second"])
}

/// In-memory Keychain, shaped after `ProviderStoreKeychainClient`, with a read failure switch.
final class ModelStoreKeychainClient: KeychainItemClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var shouldFailReads = false

    var failReads: Bool {
        get { lock.withLock { shouldFailReads } }
        set { lock.withLock { shouldFailReads = newValue } }
    }

    func read(service: String, account: String) -> KeychainItemReadResult {
        lock.withLock {
            if shouldFailReads { return .failure(errSecInternalError) }
            return values[account].map(KeychainItemReadResult.found) ?? .notFound
        }
    }

    func add(_ data: Data, service: String, account: String) -> OSStatus {
        lock.withLock {
            guard values[account] == nil else { return errSecDuplicateItem }
            values[account] = data
            return errSecSuccess
        }
    }

    func update(_ data: Data, service: String, account: String) -> OSStatus {
        lock.withLock {
            guard values[account] != nil else { return errSecItemNotFound }
            values[account] = data
            return errSecSuccess
        }
    }

    func delete(service: String, account: String) -> OSStatus {
        lock.withLock {
            values.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}
