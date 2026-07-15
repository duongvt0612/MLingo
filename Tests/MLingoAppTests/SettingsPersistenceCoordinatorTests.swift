import Foundation
import MLingoCore
import Testing
@testable import MLingoApp

@Test
func settingsPersistenceCommitWritesCredentialsConfigurationAndSettings() async throws {
    let originalSettings = AppSettings(sourceLanguage: "English")
    let settingsStore = SettingsCoordinatorSettingsStore(settings: originalSettings)
    let profileStore = SettingsCoordinatorProfileStore(configuration: ProviderConfiguration())
    let credentialStore = SettingsCoordinatorCredentialStore()
    let coordinator = SettingsPersistenceCoordinator(
        settingsStore: settingsStore,
        profileStore: profileStore,
        credentialStore: credentialStore
    )
    let profile = settingsCoordinatorProfile()
    var draft = SettingsEditorDraft(
        appSettings: AppSettings(sourceLanguage: "Japanese"),
        profiles: [ProviderProfileDraft(profile: profile, hasStoredCredential: false)],
        selections: [
            .translation: CapabilitySelection(profileID: profile.id, model: "model"),
        ],
        overlaySelection: .automatic
    )
    let credentialID = try #require(profile.authentication.credentialID)
    draft.credentialMutations[credentialID] = .replace("new-secret")

    let snapshot = try await coordinator.commit(draft, activeCredentialID: nil)

    #expect(await settingsStore.current().sourceLanguage == "Japanese")
    #expect(await profileStore.current().profiles == [profile])
    #expect(credentialStore.value(for: credentialID) == "new-secret")
    #expect(snapshot.credentialPresence[credentialID] == true)
    #expect(snapshot.configuration.selections[.translation]?.model == "model")
}

@Test
func settingsFailureRollsBackProviderConfigurationAndCredential() async throws {
    let originalSettings = AppSettings(sourceLanguage: "English")
    let originalConfiguration = ProviderConfiguration()
    let settingsStore = SettingsCoordinatorSettingsStore(
        settings: originalSettings,
        saveFailures: [SettingsCoordinatorTestError.writeFailed]
    )
    let profileStore = SettingsCoordinatorProfileStore(configuration: originalConfiguration)
    let credentialStore = SettingsCoordinatorCredentialStore(values: [CredentialID("secret"): "old"])
    let coordinator = SettingsPersistenceCoordinator(
        settingsStore: settingsStore,
        profileStore: profileStore,
        credentialStore: credentialStore
    )
    let profile = settingsCoordinatorProfile(credentialID: CredentialID("secret"))
    var draft = SettingsEditorDraft(
        appSettings: AppSettings(sourceLanguage: "Japanese"),
        profiles: [ProviderProfileDraft(profile: profile, hasStoredCredential: true)],
        selections: [.translation: CapabilitySelection(profileID: profile.id, model: "model")],
        overlaySelection: .automatic
    )
    draft.credentialMutations[CredentialID("secret")] = .replace("new")

    await #expect(throws: SettingsPersistenceError.self) {
        try await coordinator.commit(draft, activeCredentialID: nil)
    }

    #expect(await settingsStore.current() == originalSettings)
    #expect(await profileStore.current() == originalConfiguration)
    #expect(credentialStore.value(for: CredentialID("secret")) == "old")
}

@Test
func rollbackFailureReportsPrimaryAndRollbackDescriptions() async throws {
    let settingsStore = SettingsCoordinatorSettingsStore(
        settings: AppSettings(),
        saveFailures: [
            SettingsCoordinatorTestError.writeFailed,
            SettingsCoordinatorTestError.rollbackFailed,
        ]
    )
    let profileStore = SettingsCoordinatorProfileStore(configuration: ProviderConfiguration())
    let credentialStore = SettingsCoordinatorCredentialStore()
    let coordinator = SettingsPersistenceCoordinator(
        settingsStore: settingsStore,
        profileStore: profileStore,
        credentialStore: credentialStore
    )
    let profile = settingsCoordinatorProfile()
    let draft = SettingsEditorDraft(
        appSettings: AppSettings(sourceLanguage: "Japanese"),
        profiles: [ProviderProfileDraft(profile: profile, hasStoredCredential: false)],
        selections: [.translation: CapabilitySelection(profileID: profile.id, model: "model")],
        overlaySelection: .automatic
    )

    do {
        _ = try await coordinator.commit(draft, activeCredentialID: nil)
        Issue.record("Expected transaction failure")
    } catch let error as SettingsPersistenceError {
        guard case .transactionFailed(let primary, let rollback) = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        #expect(primary.contains("write failed"))
        #expect(rollback?.contains("rollback failed") == true)
    }
}

@Test
func activeCredentialMutationIsRejectedBeforeAnyStoreWrite() async throws {
    let settingsStore = SettingsCoordinatorSettingsStore(settings: AppSettings())
    let profileStore = SettingsCoordinatorProfileStore(configuration: ProviderConfiguration())
    let credentialID = CredentialID("active")
    let credentialStore = SettingsCoordinatorCredentialStore(values: [credentialID: "old"])
    let coordinator = SettingsPersistenceCoordinator(
        settingsStore: settingsStore,
        profileStore: profileStore,
        credentialStore: credentialStore
    )
    let profile = settingsCoordinatorProfile(credentialID: credentialID)
    var draft = SettingsEditorDraft(
        appSettings: AppSettings(),
        profiles: [ProviderProfileDraft(profile: profile, hasStoredCredential: true)],
        selections: [.translation: CapabilitySelection(profileID: profile.id, model: "model")],
        overlaySelection: .automatic
    )
    draft.credentialMutations[credentialID] = .remove

    await #expect(throws: SettingsPersistenceError.activeCredentialMutation(credentialID)) {
        try await coordinator.commit(draft, activeCredentialID: credentialID)
    }

    #expect(await settingsStore.saveCount() == 0)
    #expect(await profileStore.saveCount() == 0)
    #expect(credentialStore.value(for: credentialID) == "old")
}

@Test
func emptyCredentialReplacementIsRejectedWithoutWrites() async throws {
    let settingsStore = SettingsCoordinatorSettingsStore(settings: AppSettings())
    let profileStore = SettingsCoordinatorProfileStore(configuration: ProviderConfiguration())
    let credentialStore = SettingsCoordinatorCredentialStore()
    let coordinator = SettingsPersistenceCoordinator(
        settingsStore: settingsStore,
        profileStore: profileStore,
        credentialStore: credentialStore
    )
    let profile = settingsCoordinatorProfile()
    let credentialID = try #require(profile.authentication.credentialID)
    var draft = SettingsEditorDraft(
        appSettings: AppSettings(),
        profiles: [ProviderProfileDraft(profile: profile, hasStoredCredential: false)],
        selections: [.translation: CapabilitySelection(profileID: profile.id, model: "model")],
        overlaySelection: .automatic
    )
    draft.credentialMutations[credentialID] = .replace("   ")

    await #expect(throws: SettingsPersistenceError.invalidDraft([
        .emptyCredentialReplacement(credentialID),
    ])) {
        try await coordinator.commit(draft, activeCredentialID: nil)
    }

    #expect(await settingsStore.saveCount() == 0)
    #expect(await profileStore.saveCount() == 0)
    #expect(credentialStore.value(for: credentialID) == nil)
}

private enum SettingsCoordinatorTestError: LocalizedError {
    case writeFailed
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .writeFailed: "write failed"
        case .rollbackFailed: "rollback failed"
        }
    }
}

private actor SettingsCoordinatorSettingsStore: SettingsStoreProtocol {
    private var settings: AppSettings
    private var failures: [SettingsCoordinatorTestError]
    private var saves = 0

    init(settings: AppSettings, saveFailures: [SettingsCoordinatorTestError] = []) {
        self.settings = settings
        failures = saveFailures
    }

    func load() async throws -> AppSettings { settings }

    func save(_ settings: AppSettings) async throws {
        saves += 1
        if !failures.isEmpty { throw failures.removeFirst() }
        self.settings = settings
    }

    func current() -> AppSettings { settings }
    func saveCount() -> Int { saves }
}

private actor SettingsCoordinatorProfileStore: ProviderProfileStoreProtocol {
    private var configuration: ProviderConfiguration
    private var saves = 0

    init(configuration: ProviderConfiguration) {
        self.configuration = configuration
    }

    func load() async throws -> ProviderConfiguration { configuration }
    func save(_ configuration: ProviderConfiguration) async throws {
        saves += 1
        self.configuration = configuration
    }

    func current() -> ProviderConfiguration { configuration }
    func saveCount() -> Int { saves }
}

private final class SettingsCoordinatorCredentialStore: ProviderCredentialStoreProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [CredentialID: String]

    init(values: [CredentialID: String] = [:]) {
        self.values = values
    }

    func loadCredential(for id: CredentialID) throws -> String? {
        lock.withLock { values[id] }
    }

    func saveCredential(_ secret: String, for id: CredentialID) throws {
        lock.withLock { values[id] = secret }
    }

    func deleteCredential(for id: CredentialID) throws {
        lock.withLock { values[id] = nil }
    }

    func value(for id: CredentialID) -> String? {
        lock.withLock { values[id] }
    }
}

private func settingsCoordinatorProfile(
    credentialID: CredentialID = CredentialID("credential")
) -> ProviderProfile {
    ProviderProfile(
        name: "Remote",
        kind: .custom,
        endpoint: URL(string: "https://example.com/v1")!,
        apiStyle: .responses,
        authentication: .bearer(credentialID: credentialID),
        models: [.translation: ["model"]]
    )
}
