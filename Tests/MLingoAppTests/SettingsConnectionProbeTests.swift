import Foundation
import MLingoCore
import Testing
@testable import MLingoApp

@Test @MainActor
func connectionTestUsesUnsavedProfileAndReplacementSecret() async throws {
    let storedID = CredentialID("stored")
    let profile = ProviderProfile(
        name: "Remote",
        kind: .custom,
        endpoint: URL(string: "https://saved.example.com/v1")!,
        apiStyle: .responses,
        authentication: .bearer(credentialID: storedID),
        models: [.translation: ["saved-model"]]
    )
    let snapshot = SettingsEditorSnapshot(
        appSettings: AppSettings(),
        configuration: ProviderConfiguration(profiles: [profile]),
        overlaySelection: .automatic,
        credentialPresence: [storedID: true]
    )
    let credentials = SettingsProbeCredentialStore(values: [storedID: "stored-secret"])
    let probe = SettingsProbeSpy(
        result: ProviderConnectionTestResult(
            succeeded: true,
            message: "Connected",
            models: ["discovered"]
        )
    )
    let editor = SettingsEditorViewModel(
        snapshot: snapshot,
        credentialStore: credentials,
        connectionProbe: probe
    )
    editor.draft.profiles[0].endpoint = "https://draft.example.com/v1"
    editor.draft.profiles[0].models[.translation] = ["draft-model"]
    editor.draft.credentialMutations[storedID] = .replace("draft-secret")

    editor.startConnectionTest(profileID: profile.id)
    try await settingsProbeEventually {
        if case .success = editor.connectionTestState { return true }
        return false
    }

    let request = await probe.lastRequest()
    #expect(request?.profile.endpoint?.host == "draft.example.com")
    #expect(request?.profile.models[.translation] == ["draft-model"])
    #expect(request?.secret == "draft-secret")
    #expect(editor.discoveredModels == ["discovered"])
    #expect(credentials.value(for: storedID) == "stored-secret")
}

@Test @MainActor
func connectionTestReadsUnchangedSecretOnlyInsideProbe() async throws {
    let credentialID = CredentialID("stored")
    let profile = ProviderProfile(
        name: "Remote",
        kind: .custom,
        endpoint: URL(string: "https://remote.example.com/v1")!,
        apiStyle: .responses,
        authentication: .bearer(credentialID: credentialID),
        models: [.translation: ["model"]]
    )
    let credentials = SettingsProbeCredentialStore(values: [credentialID: "stored-secret"])
    let probe = SettingsProbeSpy(result: ProviderConnectionTestResult(
        succeeded: true,
        message: "Connected",
        models: []
    ))
    let editor = SettingsEditorViewModel(
        snapshot: SettingsEditorSnapshot(
            appSettings: AppSettings(),
            configuration: ProviderConfiguration(profiles: [profile]),
            overlaySelection: .automatic,
            credentialPresence: [credentialID: true]
        ),
        credentialStore: credentials,
        connectionProbe: probe
    )

    editor.startConnectionTest(profileID: profile.id)
    try await settingsProbeEventually {
        if case .success = editor.connectionTestState { return true }
        return false
    }

    #expect(await probe.lastRequest()?.secret == "stored-secret")
    #expect(editor.draft.credentialMutations[credentialID] == nil)
    #expect(!String(describing: editor.connectionTestState).contains("stored-secret"))
}

@Test @MainActor
func staleConnectionResultCannotOverwriteTheNewProfileResult() async throws {
    let first = OpenAICompatiblePresets.make(kind: .custom, name: "First", models: [.translation: ["a"]])
    let second = OpenAICompatiblePresets.make(kind: .custom, name: "Second", models: [.translation: ["b"]])
    var firstDraft = ProviderProfileDraft(profile: first, hasStoredCredential: false)
    firstDraft.endpoint = "https://slow.example.com/v1"
    var secondDraft = ProviderProfileDraft(profile: second, hasStoredCredential: false)
    secondDraft.endpoint = "https://fast.example.com/v1"
    let snapshot = SettingsEditorSnapshot(
        appSettings: AppSettings(),
        configuration: ProviderConfiguration(),
        overlaySelection: .automatic,
        credentialPresence: [:]
    )
    let editor = SettingsEditorViewModel(
        snapshot: snapshot,
        credentialStore: SettingsProbeCredentialStore(),
        connectionProbe: SettingsDelayedProbe()
    )
    editor.draft.profiles = [firstDraft, secondDraft]

    editor.startConnectionTest(profileID: first.id)
    editor.startConnectionTest(profileID: second.id)

    try await settingsProbeEventually {
        editor.connectionTestState == .success(
            profileID: second.id,
            message: "fast",
            models: ["fast-model"]
        )
    }
    try? await Task.sleep(for: .milliseconds(80))
    #expect(editor.connectionTestState == .success(
        profileID: second.id,
        message: "fast",
        models: ["fast-model"]
    ))
}

@Test @MainActor
func cancellingConnectionTestReturnsToIdle() async throws {
    let profile = OpenAICompatiblePresets.make(kind: .custom, models: [.translation: ["a"]])
    var profileDraft = ProviderProfileDraft(profile: profile, hasStoredCredential: false)
    profileDraft.endpoint = "https://slow.example.com/v1"
    let editor = SettingsEditorViewModel(
        snapshot: SettingsEditorSnapshot(
            appSettings: AppSettings(),
            configuration: ProviderConfiguration(),
            overlaySelection: .automatic,
            credentialPresence: [:]
        ),
        credentialStore: SettingsProbeCredentialStore(),
        connectionProbe: SettingsDelayedProbe()
    )
    editor.draft.profiles = [profileDraft]

    editor.startConnectionTest(profileID: profile.id)
    #expect(editor.connectionTestState == .running(profileID: profile.id))
    editor.cancelConnectionTest()

    #expect(editor.connectionTestState == .idle)
    try? await Task.sleep(for: .milliseconds(80))
    #expect(editor.connectionTestState == .idle)
}

private actor SettingsProbeSpy: ProviderConnectionProbing {
    struct Request: Sendable {
        let profile: ProviderProfile
        let secret: String?
    }

    private let result: ProviderConnectionTestResult
    private var request: Request?

    init(result: ProviderConnectionTestResult) {
        self.result = result
    }

    func testConnection(
        profile: ProviderProfile,
        secretProvider: @Sendable (CredentialID) throws -> String?
    ) async throws -> ProviderConnectionTestResult {
        let secret = try profile.authentication.credentialID.flatMap(secretProvider)
        request = Request(profile: profile, secret: secret)
        return result
    }

    func lastRequest() -> Request? { request }
}

private actor SettingsDelayedProbe: ProviderConnectionProbing {
    func testConnection(
        profile: ProviderProfile,
        secretProvider: @Sendable (CredentialID) throws -> String?
    ) async throws -> ProviderConnectionTestResult {
        if profile.endpoint?.host == "slow.example.com" {
            try? await Task.sleep(for: .milliseconds(60))
            return ProviderConnectionTestResult(
                succeeded: true,
                message: "slow",
                models: ["slow-model"]
            )
        }
        return ProviderConnectionTestResult(
            succeeded: true,
            message: "fast",
            models: ["fast-model"]
        )
    }
}

private final class SettingsProbeCredentialStore: ProviderCredentialStoreProtocol,
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

@MainActor
private func settingsProbeEventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition was not met before timeout")
}
