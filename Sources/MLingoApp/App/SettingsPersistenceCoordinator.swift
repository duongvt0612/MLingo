import Foundation
import MLingoCore

enum SettingsPersistenceError: LocalizedError, Equatable, Sendable {
    case invalidDraft([SettingsDraftIssue])
    case activeCredentialMutation(CredentialID)
    case transactionFailed(primary: String, rollback: String?)

    var errorDescription: String? {
        switch self {
        case .invalidDraft:
            "Review the invalid Settings fields before saving."
        case .activeCredentialMutation:
            "Stop live translation before changing the credential used by the active provider."
        case .transactionFailed(let primary, let rollback):
            if let rollback {
                "Settings could not be saved: \(primary) Rollback also failed: \(rollback)"
            } else {
                "Settings could not be saved: \(primary)"
            }
        }
    }
}

actor SettingsPersistenceCoordinator {
    private let settingsStore: any SettingsStoreProtocol
    private let profileStore: any ProviderProfileStoreProtocol
    private let credentialStore: any ProviderCredentialStoreProtocol

    init(
        settingsStore: any SettingsStoreProtocol,
        profileStore: any ProviderProfileStoreProtocol,
        credentialStore: any ProviderCredentialStoreProtocol
    ) {
        self.settingsStore = settingsStore
        self.profileStore = profileStore
        self.credentialStore = credentialStore
    }

    func load(
        overlaySelection: OverlayDisplaySelection
    ) async throws -> SettingsEditorSnapshot {
        let settings = try await settingsStore.load()
        let configuration = try await profileStore.load()
        return try snapshot(
            settings: settings,
            configuration: configuration,
            overlaySelection: overlaySelection
        )
    }

    func commit(
        _ draft: SettingsEditorDraft,
        activeCredentialID: CredentialID?
    ) async throws -> SettingsEditorSnapshot {
        let validation = draft.validation
        guard validation.isValid else {
            throw SettingsPersistenceError.invalidDraft(validation.issues)
        }
        if let activeCredentialID,
           draft.credentialMutations[activeCredentialID] != nil {
            throw SettingsPersistenceError.activeCredentialMutation(activeCredentialID)
        }

        let configuration = ProviderConfiguration(
            profiles: validation.normalizedProfiles,
            selections: draft.selections
        )
        let originalSettings = try await settingsStore.load()
        let originalConfiguration = try await profileStore.load()
        let mutationIDs = draft.credentialMutations.keys.sorted {
            $0.rawValue < $1.rawValue
        }
        var originalCredentials: [CredentialID: String?] = [:]
        for id in mutationIDs {
            originalCredentials[id] = try credentialStore.loadCredential(for: id)
        }

        var attemptedCredentials: [CredentialID] = []
        var attemptedConfiguration = false
        var attemptedSettings = false

        do {
            for id in mutationIDs {
                attemptedCredentials.append(id)
                try apply(draft.credentialMutations[id], to: id)
            }

            attemptedConfiguration = true
            try await profileStore.save(configuration)

            attemptedSettings = true
            try await settingsStore.save(validation.normalizedAppSettings)

            return try snapshot(
                settings: validation.normalizedAppSettings,
                configuration: configuration,
                overlaySelection: draft.overlaySelection
            )
        } catch {
            let primary = error.localizedDescription
            let rollback = await rollback(
                originalSettings: originalSettings,
                originalConfiguration: originalConfiguration,
                originalCredentials: originalCredentials,
                attemptedSettings: attemptedSettings,
                attemptedConfiguration: attemptedConfiguration,
                attemptedCredentials: attemptedCredentials
            )
            throw SettingsPersistenceError.transactionFailed(
                primary: primary,
                rollback: rollback
            )
        }
    }

    private func apply(_ mutation: CredentialMutation?, to id: CredentialID) throws {
        switch mutation {
        case .replace(let secret):
            try credentialStore.saveCredential(
                secret.trimmingCharacters(in: .whitespacesAndNewlines),
                for: id
            )
        case .remove:
            try credentialStore.deleteCredential(for: id)
        case nil:
            break
        }
    }

    private func rollback(
        originalSettings: AppSettings,
        originalConfiguration: ProviderConfiguration,
        originalCredentials: [CredentialID: String?],
        attemptedSettings: Bool,
        attemptedConfiguration: Bool,
        attemptedCredentials: [CredentialID]
    ) async -> String? {
        var failures: [String] = []

        if attemptedSettings {
            do {
                try await settingsStore.save(originalSettings)
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        if attemptedConfiguration {
            do {
                try await profileStore.save(originalConfiguration)
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        for id in attemptedCredentials.reversed() {
            do {
                if let secret = originalCredentials[id] ?? nil {
                    try credentialStore.saveCredential(secret, for: id)
                } else {
                    try credentialStore.deleteCredential(for: id)
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        return failures.isEmpty ? nil : failures.joined(separator: " ")
    }

    private func snapshot(
        settings: AppSettings,
        configuration: ProviderConfiguration,
        overlaySelection: OverlayDisplaySelection
    ) throws -> SettingsEditorSnapshot {
        let credentialIDs = Set(configuration.profiles.compactMap {
            $0.authentication.credentialID
        })
        var presence: [CredentialID: Bool] = [:]
        for id in credentialIDs {
            presence[id] = try credentialStore.loadCredential(for: id) != nil
        }
        return SettingsEditorSnapshot(
            appSettings: settings,
            configuration: configuration,
            overlaySelection: overlaySelection,
            credentialPresence: presence
        )
    }
}
