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
    enum ConnectionTestState: Equatable, Sendable {
        case idle
        case running(profileID: UUID)
        case success(profileID: UUID, message: String, models: [String])
        case failure(profileID: UUID, message: String)
    }

    var selectedDestination: SettingsDestination = .general
    var draft: SettingsEditorDraft
    private(set) var snapshot: SettingsEditorSnapshot
    private(set) var connectionTestState: ConnectionTestState = .idle
    @ObservationIgnored private let credentialStore: (any ProviderCredentialStoreProtocol)?
    @ObservationIgnored private let connectionProbe: (any ProviderConnectionProbing)?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = 0

    init(
        snapshot: SettingsEditorSnapshot,
        credentialStore: (any ProviderCredentialStoreProtocol)? = nil,
        connectionProbe: (any ProviderConnectionProbing)? = nil
    ) {
        self.snapshot = snapshot
        self.credentialStore = credentialStore
        self.connectionProbe = connectionProbe
        draft = snapshot.makeDraft()
    }

    var discoveredModels: [String] {
        guard case .success(_, _, let models) = connectionTestState else { return [] }
        return models
    }

    func discardChanges() {
        cancelConnectionTest()
        draft = snapshot.makeDraft()
    }

    func acceptCommittedSnapshot(_ snapshot: SettingsEditorSnapshot) {
        self.snapshot = snapshot
        draft = snapshot.makeDraft()
    }

    func startConnectionTest(profileID: UUID) {
        cancelConnectionTest()
        guard let profile = draft.profiles.first(where: { $0.id == profileID }) else {
            connectionTestState = .failure(
                profileID: profileID,
                message: "Provider profile is unavailable."
            )
            return
        }
        guard let connectionProbe else {
            connectionTestState = .failure(
                profileID: profileID,
                message: "Connection testing is unavailable."
            )
            return
        }

        connectionGeneration += 1
        let generation = connectionGeneration
        let normalizedProfile = profile.normalizedProfile
        let mutations = draft.credentialMutations
        let credentialStore = credentialStore
        connectionTestState = .running(profileID: profileID)

        connectionTask = Task { [weak self] in
            do {
                let result = try await connectionProbe.testConnection(
                    profile: normalizedProfile,
                    secretProvider: { credentialID in
                        switch mutations[credentialID] {
                        case .replace(let secret):
                            return secret.trimmingCharacters(in: .whitespacesAndNewlines)
                        case .remove:
                            return nil
                        case nil:
                            return try credentialStore?.loadCredential(for: credentialID)
                        }
                    }
                )
                try Task.checkCancellation()
                guard let self,
                      self.connectionGeneration == generation
                else { return }
                self.connectionTestState = .success(
                    profileID: profileID,
                    message: result.message,
                    models: result.models
                )
                self.connectionTask = nil
            } catch is CancellationError {
                guard let self,
                      self.connectionGeneration == generation
                else { return }
                self.connectionTestState = .idle
                self.connectionTask = nil
            } catch {
                guard let self,
                      self.connectionGeneration == generation
                else { return }
                self.connectionTestState = .failure(
                    profileID: profileID,
                    message: error.localizedDescription
                )
                self.connectionTask = nil
            }
        }
    }

    func cancelConnectionTest() {
        connectionGeneration += 1
        connectionTask?.cancel()
        connectionTask = nil
        connectionTestState = .idle
    }
}
