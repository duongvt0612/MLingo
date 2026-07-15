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
