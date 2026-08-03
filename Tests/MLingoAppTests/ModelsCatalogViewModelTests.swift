import Foundation
import MLingoCore
import Testing
@testable import MLingoApp

private let whisperID = ModelID("mlx-community/whisper-base-mlx")
private let chatID = ModelID("mlx-community/Qwen3-0.6B-4bit")

@MainActor
private func makeCatalogViewModel(
    manager: FakeModelCatalogManager,
    commands: CommandRecorder = CommandRecorder()
) -> ModelsCatalogViewModel {
    ModelsCatalogViewModel(
        manager: manager,
        performExternalCommand: { command in commands.record(command) }
    )
}

@Test @MainActor
func startPublishesOneRowPerCatalogEntryWithItsState() async throws {
    let manager = FakeModelCatalogManager(states: [whisperID: .installed, chatID: .notInstalled])
    let catalog = makeCatalogViewModel(manager: manager)

    await catalog.start()

    // Rows follow catalog order, including entries the fake was given no state for.
    #expect(catalog.rows.map(\.id) == MLingoModelCatalog.v1.map(\.id))
    #expect(catalog.rows[0].presentation.title == "Installed")
    #expect(catalog.rows[1].presentation.title == "Not installed")
    #expect(catalog.rows[2].presentation.title == "Not installed")
    #expect(catalog.usage?.installedBytes == 148_000_000)
    catalog.stop()
}

@Test @MainActor
func downloadingForwardsToTheManagerAndFollowsTheProgressStream() async throws {
    let manager = FakeModelCatalogManager(states: [whisperID: .notInstalled])
    let catalog = makeCatalogViewModel(manager: manager)
    await catalog.start()

    catalog.download(whisperID)
    await manager.publish(whisperID, .downloading(completedBytes: 74, totalBytes: 148))

    try await eventuallyOnMain { catalog.rows[0].presentation.progressFraction == 0.5 }
    #expect(await manager.installed == [whisperID])
    catalog.stop()
}

@Test @MainActor
func cancelAndRetryReachTheManager() async throws {
    let manager = FakeModelCatalogManager(states: [whisperID: .downloading(completedBytes: 1, totalBytes: 2)])
    let catalog = makeCatalogViewModel(manager: manager)
    await catalog.start()

    catalog.cancel(whisperID)
    catalog.retry(whisperID)

    try await eventuallyOnMain { await manager.cancelled == [whisperID] }
    try await eventuallyOnMain { await manager.retried == [whisperID] }
    catalog.stop()
}

@Test @MainActor
func deletionNeedsAnExplicitConfirmation() async throws {
    let manager = FakeModelCatalogManager(states: [whisperID: .installed])
    let catalog = makeCatalogViewModel(manager: manager)
    await catalog.start()

    catalog.requestDeletion(whisperID)
    #expect(catalog.pendingDeletion == whisperID)
    #expect(await manager.deleted.isEmpty)

    catalog.cancelDeletion()
    #expect(catalog.pendingDeletion == nil)
    await catalog.confirmDeletion()
    #expect(await manager.deleted.isEmpty, "Confirming without a pending request must delete nothing")

    catalog.requestDeletion(whisperID)
    await catalog.confirmDeletion()
    #expect(await manager.deleted == [whisperID])
    #expect(catalog.pendingDeletion == nil)
    catalog.stop()
}

@Test @MainActor
func aRefusedDeletionIsReportedNextToTheModelWithItsRecoveryAction() async throws {
    let manager = FakeModelCatalogManager(
        states: [whisperID: .installed],
        deleteError: ModelStoreError(issue: .modelInUse(whisperID))
    )
    let commands = CommandRecorder()
    let catalog = makeCatalogViewModel(manager: manager, commands: commands)
    await catalog.start()

    catalog.requestDeletion(whisperID)
    await catalog.confirmDeletion()

    let row = try #require(catalog.rows.first { $0.id == whisperID })
    #expect(row.errorMessage?.contains("in use") == true)
    #expect(row.recoveryAction == .stopActiveSession)
    // The failure belongs to this row, not to the pane.
    #expect(catalog.rows.allSatisfy { $0.id == whisperID || $0.errorMessage == nil })

    catalog.recover(whisperID)
    #expect(commands.recorded == [.stopSession])
    catalog.stop()
}

@Test @MainActor
func recoveringAMissingTokenAsksTheViewToFocusTheTokenField() async throws {
    let manager = FakeModelCatalogManager(
        states: [whisperID: .failed(ModelStoreError(issue: .authenticationRequired))]
    )
    let commands = CommandRecorder()
    let catalog = makeCatalogViewModel(manager: manager, commands: commands)
    await catalog.start()

    catalog.recover(whisperID)

    #expect(commands.recorded == [.focusToken])
    catalog.stop()
}

@Test @MainActor
func recoveringATransportFailureRetriesWithoutLeavingTheViewModel() async throws {
    let manager = FakeModelCatalogManager(
        states: [whisperID: .failed(ModelStoreError(issue: .transportFailure))]
    )
    let commands = CommandRecorder()
    let catalog = makeCatalogViewModel(manager: manager, commands: commands)
    await catalog.start()

    catalog.recover(whisperID)

    try await eventuallyOnMain { await manager.retried == [whisperID] }
    #expect(commands.recorded.isEmpty)
    catalog.stop()
}

@Test @MainActor
func diskFiguresAreRefreshedOnInstallationChangesButNotOnEveryProgressTick() async throws {
    let manager = FakeModelCatalogManager(states: [whisperID: .notInstalled])
    let catalog = makeCatalogViewModel(manager: manager)
    await catalog.start()
    let afterStart = await manager.catalogSnapshotCalls

    for completed in stride(from: Int64(10), through: 100, by: 10) {
        await manager.publish(whisperID, .downloading(completedBytes: completed, totalBytes: 148))
    }
    try await eventuallyOnMain { catalog.rows[0].presentation.title == "Downloading" }
    #expect(await manager.catalogSnapshotCalls == afterStart,
            "Walking the store on every progress tick would be wasteful")

    await manager.publish(whisperID, .installed)
    try await eventuallyOnMain { await manager.catalogSnapshotCalls > afterStart }
    catalog.stop()
}

@Test @MainActor
func stopEndsTheSubscriptionSoAClosedPaneStopsWorking() async throws {
    let manager = FakeModelCatalogManager(states: [whisperID: .notInstalled])
    let catalog = makeCatalogViewModel(manager: manager)
    await catalog.start()

    catalog.stop()
    await manager.publish(whisperID, .installed)
    try await Task.sleep(for: .milliseconds(30))

    #expect(catalog.rows[0].presentation.title == "Not installed")
}

// MARK: - Helpers

@MainActor
private func eventuallyOnMain(
    timeout: Duration = .seconds(1),
    _ condition: @MainActor () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition was not met within \(timeout)", sourceLocation: sourceLocation)
}

private final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ModelRecoveryCommand] = []

    var recorded: [ModelRecoveryCommand] { lock.withLock { storage } }

    func record(_ command: ModelRecoveryCommand) {
        lock.withLock { storage.append(command) }
    }
}

private actor FakeModelCatalogManager: ModelCatalogManaging {
    private var states: [ModelID: ModelLifecycleState]
    private let deleteError: (any Error)?
    private var continuations: [UUID: AsyncStream<ModelStateSnapshot>.Continuation] = [:]
    private(set) var installed: [ModelID] = []
    private(set) var retried: [ModelID] = []
    private(set) var cancelled: [ModelID] = []
    private(set) var deleted: [ModelID] = []
    private(set) var catalogSnapshotCalls = 0

    init(states: [ModelID: ModelLifecycleState], deleteError: (any Error)? = nil) {
        self.states = states
        self.deleteError = deleteError
    }

    func catalogSnapshot() -> ModelCatalogSnapshot {
        catalogSnapshotCalls += 1
        let entries = MLingoModelCatalog.v1.map { entry in
            ModelStatus(
                entry: entry,
                state: states[entry.id] ?? .notInstalled,
                installedBytes: states[entry.id] == .installed ? 148_000_000 : nil
            )
        }
        return ModelCatalogSnapshot(
            entries: entries,
            usage: ModelStorageUsage(
                installedBytes: 148_000_000,
                stagingBytes: 0,
                quarantineBytes: 0,
                hubCacheBytes: 0,
                perModel: [:],
                totalBytes: 148_000_000
            )
        )
    }

    func stateStream() -> AsyncStream<ModelStateSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ModelStateSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuation.yield(ModelStateSnapshot(states: states))
        return stream
    }

    func install(_ id: ModelID) { installed.append(id) }
    func retry(_ id: ModelID) { retried.append(id) }
    func cancel(_ id: ModelID) { cancelled.append(id) }

    func delete(_ id: ModelID) throws {
        if let deleteError { throw deleteError }
        deleted.append(id)
        states[id] = .notInstalled
        publishCurrent()
    }

    func publish(_ id: ModelID, _ state: ModelLifecycleState) {
        states[id] = state
        publishCurrent()
    }

    private func publishCurrent() {
        let snapshot = ModelStateSnapshot(states: states)
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

@Test @MainActor
func retryingClearsThePreviousFailureImmediatelyRatherThanWaitingForAState() async throws {
    let manager = FakeModelCatalogManager(
        states: [whisperID: .installed],
        deleteError: ModelStoreError(issue: .modelInUse(whisperID))
    )
    let catalog = makeCatalogViewModel(manager: manager)
    await catalog.start()
    catalog.requestDeletion(whisperID)
    await catalog.confirmDeletion()
    #expect(catalog.rows[0].errorMessage != nil)

    catalog.download(whisperID)

    // The fake publishes nothing in response, which is the point: a stale failure must not sit
    // next to a model the user has just asked to download again.
    #expect(catalog.rows[0].errorMessage == nil)
    catalog.stop()
}
