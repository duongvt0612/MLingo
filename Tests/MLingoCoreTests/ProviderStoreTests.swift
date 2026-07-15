import Foundation
import Security
import Testing
@testable import MLingoCore

@Test
func providerProfileStoreRoundTripsProfilesAndSelectionsWithoutSecrets() async throws {
    let suiteName = "MLingoProviderStoreTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsProviderProfileStore(defaults: defaults, key: "providers")
    let profile = ProviderProfile(
        name: "OpenAI",
        kind: .openAI,
        endpoint: URL(string: "https://api.openai.com/v1")!,
        apiStyle: .responses,
        authentication: .bearer(credentialID: CredentialID("profile-secret-ref")),
        models: [.translation: ["gpt-test"]]
    )
    let configuration = ProviderConfiguration(
        profiles: [profile],
        selections: [
            .translation: CapabilitySelection(profileID: profile.id, model: "gpt-test"),
        ]
    )

    try await store.save(configuration)

    #expect(try await store.load() == configuration)
    let persisted = String(
        decoding: try #require(defaults.data(forKey: "providers")),
        as: UTF8.self
    )
    #expect(persisted.contains("profile-secret-ref"))
    #expect(!persisted.contains("sk-actual-secret"))
}

@Test
func providerProfileStoreRejectsInvalidProfilesWithoutReplacingStoredData() async throws {
    let suiteName = "MLingoProviderStoreTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsProviderProfileStore(defaults: defaults, key: "providers")
    let original = ProviderConfiguration()
    try await store.save(original)
    let originalData = defaults.data(forKey: "providers")
    let invalid = ProviderProfile(
        name: "Remote HTTP",
        kind: .custom,
        endpoint: URL(string: "http://example.com/v1")!,
        apiStyle: .responses,
        authentication: .none,
        models: [.translation: ["model"]]
    )

    await #expect(throws: ProviderConfigurationError.invalidProfile(
        invalid.id,
        .remoteEndpointRequiresHTTPS
    )) {
        try await store.save(ProviderConfiguration(profiles: [invalid]))
    }
    #expect(defaults.data(forKey: "providers") == originalData)
}

@Test
func providerCredentialStoreUsesCredentialIDAsTheOnlyKeychainAccount() throws {
    let client = ProviderStoreKeychainClient()
    let store = KeychainProviderCredentialStore(
        service: "test.service",
        client: client
    )
    let first = CredentialID("profile-one")
    let second = CredentialID("profile-two")

    try store.saveCredential("secret-one", for: first)
    try store.saveCredential("secret-two", for: second)

    #expect(try store.loadCredential(for: first) == "secret-one")
    #expect(try store.loadCredential(for: second) == "secret-two")
    #expect(client.accounts == ["profile-one", "profile-two"])

    try store.deleteCredential(for: first)
    #expect(try store.loadCredential(for: first) == nil)
    #expect(try store.loadCredential(for: second) == "secret-two")
}

private final class ProviderStoreKeychainClient: KeychainItemClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    var accounts: [String] {
        lock.withLock { values.keys.sorted() }
    }

    func read(service: String, account: String) -> KeychainItemReadResult {
        lock.withLock {
            values[account].map(KeychainItemReadResult.found) ?? .notFound
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
