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
    private(set) var isSaving = false
    private(set) var saveError: String?
    @ObservationIgnored private let credentialStore: (any ProviderCredentialStoreProtocol)?
    @ObservationIgnored private let connectionProbe: (any ProviderConnectionProbing)?
    @ObservationIgnored private let persistenceCoordinator: SettingsPersistenceCoordinator?
    @ObservationIgnored private let activeCredentialID: @MainActor () -> CredentialID?
    @ObservationIgnored private let applyOverlay: @MainActor (OverlayDisplaySelection) -> Void
    @ObservationIgnored private let onCommit: @MainActor (SettingsEditorSnapshot) -> Void
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = 0

    init(
        snapshot: SettingsEditorSnapshot,
        credentialStore: (any ProviderCredentialStoreProtocol)? = nil,
        connectionProbe: (any ProviderConnectionProbing)? = nil,
        persistenceCoordinator: SettingsPersistenceCoordinator? = nil,
        activeCredentialID: @escaping @MainActor () -> CredentialID? = { nil },
        applyOverlay: @escaping @MainActor (OverlayDisplaySelection) -> Void = { _ in },
        onCommit: @escaping @MainActor (SettingsEditorSnapshot) -> Void = { _ in }
    ) {
        self.snapshot = snapshot
        self.credentialStore = credentialStore
        self.connectionProbe = connectionProbe
        self.persistenceCoordinator = persistenceCoordinator
        self.activeCredentialID = activeCredentialID
        self.applyOverlay = applyOverlay
        self.onCommit = onCommit
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

    @discardableResult
    func addProfile(kind: ProviderKind) -> UUID {
        var profile = OpenAICompatiblePresets.make(kind: kind)
        if kind == .openAI {
            profile.authentication = .bearer(
                credentialID: ProviderProfileDraft.defaultCredentialID(for: profile.id)
            )
        }
        draft.profiles.append(
            ProviderProfileDraft(profile: profile, hasStoredCredential: false)
        )
        return profile.id
    }

    func assign(profileID: UUID?, to capability: ModelCapability) {
        guard let profileID else {
            draft.selections[capability] = nil
            return
        }
        guard let profile = draft.profiles.first(where: { $0.id == profileID }),
              let model = profile.normalizedProfile.models[capability]?.first
        else {
            draft.selections[capability] = nil
            return
        }
        draft.selections[capability] = CapabilitySelection(
            profileID: profileID,
            model: model
        )
    }

    func deleteProfile(id: UUID) {
        cancelConnectionTest()
        draft.deleteProfile(id: id)
    }

    @discardableResult
    func save() async -> Bool {
        guard !isSaving else { return false }
        guard let persistenceCoordinator else {
            saveError = "Settings persistence is unavailable."
            return false
        }

        isSaving = true
        saveError = nil
        defer { isSaving = false }

        do {
            let committed = try await persistenceCoordinator.commit(
                draft,
                activeCredentialID: activeCredentialID()
            )
            applyOverlay(committed.overlaySelection)
            onCommit(committed)
            acceptCommittedSnapshot(committed)
            return true
        } catch {
            saveError = error.localizedDescription
            if case SettingsPersistenceError.transactionFailed(_, let rollback) = error,
               rollback != nil,
               let actual = try? await persistenceCoordinator.load(
                   overlaySelection: snapshot.overlaySelection
               ) {
                acceptCommittedSnapshot(actual)
            }
            return false
        }
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
