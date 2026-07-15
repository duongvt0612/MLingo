import Foundation
import MLingoCore
import Observation

struct SettingsEditorSnapshot: Equatable, Sendable {
    var appSettings: AppSettings
    var configuration: ProviderConfiguration
    var overlaySelection: OverlayDisplaySelection
    var credentialPresence: [CredentialID: Bool]

    func makeDraft() -> SettingsEditorDraft {
        SettingsEditorDraft(
            appSettings: appSettings,
            profiles: configuration.profiles.map { profile in
                ProviderProfileDraft(
                    profile: profile,
                    hasStoredCredential: profile.authentication.credentialID
                        .flatMap { credentialPresence[$0] } ?? false
                )
            },
            selections: configuration.selections,
            overlaySelection: overlaySelection
        )
    }
}

@MainActor
@Observable
final class SettingsEditorViewModel {
    var selectedDestination: SettingsDestination = .general
    var draft: SettingsEditorDraft
    private(set) var snapshot: SettingsEditorSnapshot

    init(snapshot: SettingsEditorSnapshot) {
        self.snapshot = snapshot
        draft = snapshot.makeDraft()
    }

    func discardChanges() {
        draft = snapshot.makeDraft()
    }

    func acceptCommittedSnapshot(_ snapshot: SettingsEditorSnapshot) {
        self.snapshot = snapshot
        draft = snapshot.makeDraft()
    }
}
