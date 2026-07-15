import Foundation
import MLingoCore
import Testing
@testable import MLingoApp

@Test @MainActor
func settingsDestinationsExposeTheLockedSidebarOrder() {
    #expect(SettingsDestination.allCases.map(\.title) == [
        "General",
        "Audio & Speech",
        "AI Providers",
        "Models",
        "Translation",
        "Subtitles",
        "Appearance",
        "Privacy",
    ])
    #expect(Set(SettingsDestination.allCases.map(\.systemImage)).count == 8)
}

@Test
func settingsDraftNormalizesProfilesAndReportsUnavailableSelections() throws {
    let profile = ProviderProfile(
        name: "  Local AI  ",
        kind: .ollama,
        endpoint: URL(string: "http://127.0.0.1:11434/v1")!,
        apiStyle: .chatCompletions,
        authentication: .none,
        models: [.translation: [" qwen3:4b ", "qwen3:4b", "  "]]
    )
    var draft = SettingsEditorDraft(
        appSettings: AppSettings(),
        profiles: [ProviderProfileDraft(profile: profile, hasStoredCredential: false)],
        selections: [
            .translation: CapabilitySelection(
                profileID: profile.id,
                model: "missing-model"
            ),
        ],
        overlaySelection: .automatic
    )

    let validation = draft.validation

    #expect(validation.normalizedProfiles[0].name == "Local AI")
    #expect(validation.normalizedProfiles[0].models[.translation] == ["qwen3:4b"])
    #expect(validation.issues.contains(.invalidSelection(
        .translation,
        .modelUnavailable(profile.id, .translation, "missing-model")
    )))

    draft.selections[.translation] = nil
    #expect(draft.validation.isValid)
}

@Test
func deletingProfileClearsSelectionsAndOnlyRemovesUnreferencedCredential() throws {
    let sharedCredential = CredentialID("shared")
    let first = ProviderProfile(
        name: "First",
        kind: .custom,
        endpoint: URL(string: "https://first.example.com/v1")!,
        apiStyle: .responses,
        authentication: .bearer(credentialID: sharedCredential),
        models: [.translation: ["translate"]]
    )
    let second = ProviderProfile(
        name: "Second",
        kind: .custom,
        endpoint: URL(string: "https://second.example.com/v1")!,
        apiStyle: .responses,
        authentication: .bearer(credentialID: sharedCredential),
        models: [.chat: ["chat"]]
    )
    var draft = SettingsEditorDraft(
        appSettings: AppSettings(),
        profiles: [
            ProviderProfileDraft(profile: first, hasStoredCredential: true),
            ProviderProfileDraft(profile: second, hasStoredCredential: true),
        ],
        selections: [
            .translation: CapabilitySelection(profileID: first.id, model: "translate"),
            .chat: CapabilitySelection(profileID: second.id, model: "chat"),
        ],
        overlaySelection: .automatic
    )

    draft.deleteProfile(id: first.id)

    #expect(draft.profiles.map(\.id) == [second.id])
    #expect(draft.selections[.translation] == nil)
    #expect(draft.selections[.chat]?.profileID == second.id)
    #expect(draft.credentialMutations[sharedCredential] == nil)

    draft.deleteProfile(id: second.id)
    #expect(draft.credentialMutations[sharedCredential] == .remove)
}

@Test @MainActor
func settingsEditorRoutesDestinationsAndDiscardRestoresItsSnapshot() {
    let profile = OpenAICompatiblePresets.make(
        kind: .openAI,
        models: [.translation: ["gpt-test"]]
    )
    let snapshot = SettingsEditorSnapshot(
        appSettings: AppSettings(sourceLanguage: "English"),
        configuration: ProviderConfiguration(
            profiles: [profile],
            selections: [
                .translation: CapabilitySelection(
                    profileID: profile.id,
                    model: "gpt-test"
                ),
            ]
        ),
        overlaySelection: .automatic,
        credentialPresence: [ProviderDefaults.openAICredentialID: true]
    )
    let editor = SettingsEditorViewModel(snapshot: snapshot)

    #expect(editor.selectedDestination == .general)
    editor.selectedDestination = .aiProviders
    editor.draft.appSettings.sourceLanguage = "Japanese"
    editor.draft.profiles[0].name = "Changed"
    editor.draft.credentialMutations[ProviderDefaults.openAICredentialID] = .remove

    editor.discardChanges()

    #expect(editor.selectedDestination == .aiProviders)
    #expect(editor.draft.appSettings.sourceLanguage == "English")
    #expect(editor.draft.profiles[0].name == profile.name)
    #expect(editor.draft.profiles[0].hasStoredCredential)
    #expect(editor.draft.credentialMutations.isEmpty)
}

@Test @MainActor
func settingsEditorAddsRemotePresetsWithoutChangingTheCommittedSnapshot() throws {
    let editor = SettingsEditorViewModel(snapshot: SettingsEditorSnapshot(
        appSettings: AppSettings(),
        configuration: ProviderConfiguration(),
        overlaySelection: .automatic,
        credentialPresence: [:]
    ))

    let profileID = editor.addProfile(kind: .ollama)
    let profile = try #require(editor.draft.profiles.first(where: { $0.id == profileID }))

    #expect(profile.name == "Ollama")
    #expect(profile.endpoint == "http://127.0.0.1:11434/v1")
    #expect(profile.apiStyle == .chatCompletions)
    #expect(editor.snapshot.configuration.profiles.isEmpty)
}

@Test @MainActor
func newlyAddedOpenAIProfilesReceiveIndependentCredentialReferences() throws {
    let editor = SettingsEditorViewModel(snapshot: SettingsEditorSnapshot(
        appSettings: AppSettings(),
        configuration: ProviderConfiguration(),
        overlaySelection: .automatic,
        credentialPresence: [:]
    ))

    let firstID = editor.addProfile(kind: .openAI)
    let secondID = editor.addProfile(kind: .openAI)
    let first = try #require(editor.draft.profiles.first(where: { $0.id == firstID }))
    let second = try #require(editor.draft.profiles.first(where: { $0.id == secondID }))

    #expect(first.credentialID != ProviderDefaults.openAICredentialID)
    #expect(second.credentialID != ProviderDefaults.openAICredentialID)
    #expect(first.credentialID != second.credentialID)
}

@Test @MainActor
func capabilityAssignmentRequiresAnExplicitProfileAndCanBeCleared() throws {
    let profile = ProviderProfile(
        name: "Local",
        kind: .ollama,
        endpoint: URL(string: "http://127.0.0.1:11434/v1")!,
        apiStyle: .chatCompletions,
        authentication: .none,
        models: [.translation: ["first", "second"]]
    )
    let editor = SettingsEditorViewModel(snapshot: SettingsEditorSnapshot(
        appSettings: AppSettings(),
        configuration: ProviderConfiguration(profiles: [profile]),
        overlaySelection: .automatic,
        credentialPresence: [:]
    ))

    editor.assign(profileID: profile.id, to: .translation)
    #expect(editor.draft.selections[.translation] == CapabilitySelection(
        profileID: profile.id,
        model: "first"
    ))

    editor.assign(profileID: nil, to: .translation)
    #expect(editor.draft.selections[.translation] == nil)
}
