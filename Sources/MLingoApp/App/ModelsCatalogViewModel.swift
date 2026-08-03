import Foundation
import MLingoCore
import Observation

/// Drives the Models pane.
///
/// Deliberately not part of `SettingsEditorViewModel`: downloading and deleting take effect the
/// moment they are asked for, while everything in the settings draft waits for Save. Mixing the
/// two would make "Cancel" ambiguous. The one genuinely transactional value here — the Hugging
/// Face token — stays in the settings draft and reaches this type only as
/// `hasPendingTokenChange`.
@MainActor
@Observable
final class ModelsCatalogViewModel {
    struct Row: Identifiable, Equatable {
        let id: ModelID
        let entry: ModelCatalogEntry
        let state: ModelLifecycleState
        /// Bytes actually on disk, once installed.
        let installedBytes: UInt64?
        /// A failure from a command the user just ran, shown next to this model rather than in a
        /// pane-wide banner.
        let commandError: ModelStoreError?

        var presentation: ModelRowPresentation { ModelRowPresentation(state: state) }

        /// The command failure wins over the state's own message: it is what the user just did.
        var errorMessage: String? {
            commandError?.errorDescription ?? presentation.detailIfError
        }

        var recoveryAction: ModelStoreRecoveryAction? {
            (commandError ?? state.error)?.recoveryAction
        }
    }

    private(set) var rows: [Row] = []
    private(set) var usage: ModelStorageUsage?
    private(set) var pendingDeletion: ModelID?

    @ObservationIgnored private let manager: any ModelCatalogManaging
    @ObservationIgnored private let performExternalCommand: @MainActor (ModelRecoveryCommand) -> Void
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var entries: [ModelID: ModelCatalogEntry] = [:]
    @ObservationIgnored private var order: [ModelID] = []
    @ObservationIgnored private var commandErrors: [ModelID: ModelStoreError] = [:]
    @ObservationIgnored private var installedIDs: Set<ModelID> = []

    init(
        manager: any ModelCatalogManaging,
        performExternalCommand: @escaping @MainActor (ModelRecoveryCommand) -> Void
    ) {
        self.manager = manager
        self.performExternalCommand = performExternalCommand
    }

    // MARK: - Lifecycle

    func start() async {
        guard streamTask == nil else { return }
        await refreshCatalog()
        let stream = await manager.stateStream()
        streamTask = Task { [weak self] in
            for await snapshot in stream {
                // A snapshot already buffered when the pane closed must not be applied: the
                // stream can hand one over before it notices the task was cancelled.
                guard !Task.isCancelled, let self else { return }
                await self.apply(snapshot)
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Commands

    func download(_ id: ModelID) {
        clearCommandError(id)
        Task { [manager] in await manager.install(id) }
    }

    func retry(_ id: ModelID) {
        clearCommandError(id)
        Task { [manager] in await manager.retry(id) }
    }

    func cancel(_ id: ModelID) {
        Task { [manager] in await manager.cancel(id) }
    }

    func requestDeletion(_ id: ModelID) {
        pendingDeletion = id
    }

    func cancelDeletion() {
        pendingDeletion = nil
    }

    /// Deletes only what the user confirmed. Without a pending request this does nothing, so a
    /// stray confirmation cannot remove a model.
    func confirmDeletion() async {
        guard let id = pendingDeletion else { return }
        pendingDeletion = nil
        commandErrors[id] = nil
        do {
            try await manager.delete(id)
        } catch let error as ModelStoreError {
            commandErrors[id] = error
        } catch {
            commandErrors[id] = ModelStoreError(issue: .installFailed)
        }
        await refreshCatalog()
    }

    /// Runs the single recovery action offered for a model.
    func recover(_ id: ModelID) {
        guard let row = rows.first(where: { $0.id == id }),
              let action = row.recoveryAction
        else { return }

        let command = ModelRecoveryCommand(
            action: action,
            model: id,
            message: row.errorMessage ?? ""
        )
        switch command {
        case .retry:
            retry(id)
        case .focusToken, .openPage, .stopSession, .revealStorage, .copyDiagnostics:
            performExternalCommand(command)
        }
    }

    // MARK: - State

    /// Drops a stale failure the moment the user acts on it, without waiting for the store to
    /// publish a new state — nothing may have changed there yet.
    private func clearCommandError(_ id: ModelID) {
        guard commandErrors.removeValue(forKey: id) != nil else { return }
        rows = rows.map { row in
            guard row.id == id else { return row }
            return Row(
                id: row.id,
                entry: row.entry,
                state: row.state,
                installedBytes: row.installedBytes,
                commandError: nil
            )
        }
    }

    private func apply(_ snapshot: ModelStateSnapshot) async {
        rebuildRows(states: snapshot.states)

        // Disk figures only change when a model lands or leaves; walking the store on every
        // progress tick would cost far more than it tells the user.
        let installedNow = Set(snapshot.states.filter { $0.value.isUsable }.keys)
        guard installedNow != installedIDs else { return }
        installedIDs = installedNow
        await refreshCatalog()
    }

    private func refreshCatalog() async {
        let snapshot = await manager.catalogSnapshot()
        usage = snapshot.usage
        order = snapshot.entries.map(\.entry.id)
        entries = Dictionary(
            uniqueKeysWithValues: snapshot.entries.map { ($0.entry.id, $0.entry) }
        )
        installedIDs = Set(snapshot.entries.filter(\.state.isUsable).map(\.entry.id))
        rows = snapshot.entries.map { status in
            Row(
                id: status.entry.id,
                entry: status.entry,
                state: status.state,
                installedBytes: status.installedBytes,
                commandError: commandErrors[status.entry.id]
            )
        }
    }

    private func rebuildRows(states: [ModelID: ModelLifecycleState]) {
        rows = order.compactMap { id in
            guard let entry = entries[id] else { return nil }
            let state = states[id] ?? .notInstalled
            return Row(
                id: id,
                entry: entry,
                state: state,
                installedBytes: rows.first { $0.id == id }?.installedBytes,
                commandError: commandErrors[id]
            )
        }
    }
}

private extension ModelRowPresentation {
    /// The state's own message, but only when the state is a failure.
    var detailIfError: String? { isError ? detail : nil }
}
