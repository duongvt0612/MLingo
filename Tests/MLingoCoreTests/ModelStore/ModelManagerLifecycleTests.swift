import Foundation
import Testing
@testable import MLingoCore

// MARK: - Fixtures

private let modelID = ModelID("owner/model")
private let otherID = ModelID("owner/other")
private let thirdID = ModelID("owner/third")

private func makeEntry(
    id: ModelID = modelID,
    slug: String = "model",
    repository: String = "owner/model",
    expectedBytes: UInt64 = 1_000
) throws -> ModelCatalogEntry {
    ModelCatalogEntry(
        id: id,
        slug: try #require(ModelStorageSlug(slug)),
        role: .chat,
        repository: repository,
        revision: String(repeating: "d", count: 40),
        files: ["config.json", "tokenizer.json", "model.safetensors"],
        requiredFiles: ["config.json", "tokenizer.json", "model.safetensors"],
        expectedBytes: expectedBytes
    )
}

private func makeCatalog() throws -> [ModelCatalogEntry] {
    [
        try makeEntry(),
        try makeEntry(id: otherID, slug: "other", repository: "owner/other"),
        try makeEntry(id: thirdID, slug: "third", repository: "owner/third")
    ]
}

private func validOutcome(bytesPerFile: Int = 32) -> FakeModelSnapshotDownloader.Outcome {
    .success(bytesPerFile: bytesPerFile)
}

private struct Harness {
    let temporary: TemporaryDirectory
    let layout: ModelStorageLayout
    let downloader: FakeModelSnapshotDownloader
    let manager: ModelManager

    init(
        outcomes: [FakeModelSnapshotDownloader.Outcome],
        catalog: [ModelCatalogEntry]? = nil,
        availableBytes: UInt64 = 100 * 1024 * 1024 * 1024
    ) throws {
        temporary = try TemporaryDirectory(label: "Manager")
        layout = ModelStorageLayout(root: temporary.appending("Models", isDirectory: true))
        // Rooted at the store's own cache bucket so the post-install purge is genuinely exercised.
        downloader = FakeModelSnapshotDownloader(root: layout.hubCacheRoot, outcomes: outcomes)
        manager = ModelManager(
            layout: layout,
            downloader: downloader,
            catalog: try catalog ?? makeCatalog(),
            accounting: ModelStorageAccounting(layout: layout, availableBytes: { availableBytes }),
            progressThrottle: .zero
        )
    }

    func remove() { temporary.remove() }
}

private actor StateLog {
    private(set) var states: [ModelLifecycleState] = []

    func record(_ state: ModelLifecycleState) {
        if states.last != state { states.append(state) }
    }

    func contains(inOrder expected: [ModelLifecycleState]) -> Bool {
        var remaining = expected[...]
        for state in states where remaining.first.map({ matches($0, state) }) == true {
            remaining = remaining.dropFirst()
        }
        return remaining.isEmpty
    }

    /// Compares by case, ignoring payloads that vary run to run.
    private func matches(_ expected: ModelLifecycleState, _ actual: ModelLifecycleState) -> Bool {
        switch (expected, actual) {
        case (.probing, .probing), (.queued, .queued), (.downloading, .downloading),
             (.verifying, .verifying), (.installing, .installing), (.installed, .installed),
             (.cancelled, .cancelled), (.notInstalled, .notInstalled), (.failed, .failed),
             (.quarantined, .quarantined), (.ready, .ready), (.loading, .loading):
            true
        default:
            false
        }
    }
}

private func observe(_ manager: ModelManager, _ id: ModelID) async -> (StateLog, Task<Void, Never>) {
    let log = StateLog()
    let stream = await manager.stateStream()
    let task = Task {
        for await snapshot in stream {
            await log.record(snapshot.state(for: id))
        }
    }
    return (log, task)
}

// MARK: - Happy path

@Test
func installMovesThroughEveryStageToInstalled() async throws {
    let harness = try Harness(outcomes: [validOutcome()])
    defer { harness.remove() }
    let (log, observer) = await observe(harness.manager, modelID)
    defer { observer.cancel() }

    await harness.manager.install(modelID)

    #expect(await harness.manager.state(for: modelID) == .installed)
    #expect(
        await log.contains(inOrder: [.probing, .downloading(completedBytes: 0, totalBytes: 0),
                                     .verifying, .installing, .installed])
    )
    let installed = try #require(await harness.manager.installedDirectory(for: modelID))
    #expect(FileManager.default.fileExists(atPath: installed.appending(path: "config.json").path))
}

@Test
func installPurgesTheDownloadCacheEntryOnceInstalled() async throws {
    let harness = try Harness(outcomes: [validOutcome()])
    defer { harness.remove() }

    await harness.manager.install(modelID)

    // The bytes now live in the installation; keeping the cache copy would double the footprint.
    let cached = try? FileManager.default.contentsOfDirectory(atPath: harness.layout.hubCacheRoot.path)
    #expect(cached?.isEmpty != false, "download cache still holds \(cached ?? [])")
}

@Test
func installedStateSurvivesAManagerRestart() async throws {
    let harness = try Harness(outcomes: [validOutcome()])
    defer { harness.remove() }
    await harness.manager.install(modelID)

    let reopened = ModelManager(
        layout: harness.layout,
        downloader: harness.downloader,
        catalog: try makeCatalog()
    )

    #expect(await reopened.state(for: modelID) == .installed)
    #expect(await reopened.installedDirectory(for: modelID) != nil)
}

@Test
func catalogSnapshotReportsStatePerEntryAndDiskUsage() async throws {
    let harness = try Harness(outcomes: [validOutcome(bytesPerFile: 64)])
    defer { harness.remove() }
    await harness.manager.install(modelID)

    let snapshot = await harness.manager.catalogSnapshot()
    #expect(snapshot.entries.count == 3)
    let installed = try #require(snapshot.entries.first { $0.entry.id == modelID })
    #expect(installed.state == .installed)
    #expect((installed.installedBytes ?? 0) > 64)
    #expect(snapshot.entries.filter { $0.state == .notInstalled }.count == 2)
    #expect(snapshot.usage.installedBytes > 0)
}

// MARK: - Queue

@Test
func onlyOneDownloadRunsAtATime() async throws {
    let harness = try Harness(outcomes: [validOutcome(), validOutcome(), validOutcome()])
    defer { harness.remove() }

    await withTaskGroup(of: Void.self) { group in
        for id in [modelID, otherID, thirdID] {
            group.addTask { await harness.manager.install(id) }
        }
    }

    #expect(harness.downloader.maxObservedConcurrency == 1)
    for id in [modelID, otherID, thirdID] {
        #expect(await harness.manager.state(for: id) == .installed)
    }
}

@Test
func cancellingAQueuedModelLeavesTheOthersRunnable() async throws {
    let harness = try Harness(outcomes: [.blockUntilCancelled, validOutcome()])
    defer { harness.remove() }

    let blocked = Task { await harness.manager.install(modelID) }
    try await eventually { await harness.manager.state(for: modelID).isBusy }

    let queued = Task { await harness.manager.install(otherID) }
    try await eventually {
        if case .queued = await harness.manager.state(for: otherID) { return true }
        return false
    }

    await harness.manager.cancel(otherID)
    _ = await queued.value
    #expect(await harness.manager.state(for: otherID) == .cancelled)

    await harness.manager.cancel(modelID)
    _ = await blocked.value
    #expect(await harness.manager.state(for: modelID) == .cancelled)
}

// MARK: - Cancellation and retry

@Test
func cancellingADownloadClearsStagingButKeepsTheCache() async throws {
    let harness = try Harness(outcomes: [.blockUntilCancelled])
    defer { harness.remove() }

    let task = Task { await harness.manager.install(modelID) }
    try await eventually { harness.downloader.callCount == 1 }
    await harness.manager.cancel(modelID)
    await task.value

    #expect(await harness.manager.state(for: modelID) == .cancelled)
    let staged = try FileManager.default.contentsOfDirectory(atPath: harness.layout.stagingRoot.path)
    #expect(staged.isEmpty, "cancellation left \(staged) behind")
    #expect(await harness.manager.installedDirectory(for: modelID) == nil)
}

@Test
func retryAfterATransportFailureSkipsFilesThatAlreadyArrived() async throws {
    let harness = try Harness(outcomes: [
        .failAfterWriting(files: ["config.json"], error: URLError(.networkConnectionLost)),
        validOutcome()
    ])
    defer { harness.remove() }

    await harness.manager.install(modelID)
    #expect(await harness.manager.state(for: modelID).error != nil)

    await harness.manager.retry(modelID)
    #expect(await harness.manager.state(for: modelID) == .installed)

    // Byte-range resume does not exist upstream, but a file that completed stays in the cache.
    #expect(harness.downloader.fetchedFiles.first == ["config.json"])
    #expect(harness.downloader.fetchedFiles.last?.contains("config.json") == false)
}

@Test
func aTransportFailureIsRetryableRatherThanQuarantined() async throws {
    let harness = try Harness(outcomes: [.failure(URLError(.notConnectedToInternet))])
    defer { harness.remove() }

    await harness.manager.install(modelID)

    #expect(await harness.manager.state(for: modelID) == .failed(ModelStoreError(issue: .transportFailure)))
    let quarantined = try FileManager.default.contentsOfDirectory(atPath: harness.layout.quarantineRoot.path)
    #expect(quarantined.isEmpty)
}

// MARK: - Verification failure

@Test
func verificationFailureQuarantinesAndSurvivesARestart() async throws {
    let harness = try Harness(outcomes: [.partial(files: ["config.json", "model.safetensors"])])
    defer { harness.remove() }

    await harness.manager.install(modelID)

    #expect(await harness.manager.state(for: modelID) == .quarantined(reason: .missingFile))
    #expect(await harness.manager.installedDirectory(for: modelID) == nil)
    let quarantined = try FileManager.default.contentsOfDirectory(atPath: harness.layout.quarantineRoot.path)
    #expect(quarantined.count == 1)

    let reopened = ModelManager(
        layout: harness.layout,
        downloader: harness.downloader,
        catalog: try makeCatalog()
    )
    #expect(await reopened.state(for: modelID) == .quarantined(reason: .missingFile))
}

@Test
func retryClearsQuarantineBeforeReinstalling() async throws {
    let harness = try Harness(outcomes: [.partial(files: ["config.json"]), validOutcome()])
    defer { harness.remove() }
    await harness.manager.install(modelID)
    #expect(await harness.manager.state(for: modelID).error != nil)

    await harness.manager.retry(modelID)

    #expect(await harness.manager.state(for: modelID) == .installed)
    let quarantined = try FileManager.default.contentsOfDirectory(atPath: harness.layout.quarantineRoot.path)
    #expect(quarantined.isEmpty, "stale quarantine left behind: \(quarantined)")
}

// MARK: - Deletion and leases

@Test
func deleteRemovesTheReceiptAndTheDirectory() async throws {
    let harness = try Harness(outcomes: [validOutcome()])
    defer { harness.remove() }
    await harness.manager.install(modelID)

    try await harness.manager.delete(modelID)

    #expect(await harness.manager.state(for: modelID) == .notInstalled)
    #expect(await harness.manager.installedDirectory(for: modelID) == nil)
    let installed = try FileManager.default.contentsOfDirectory(atPath: harness.layout.installedRoot.path)
    #expect(installed.isEmpty)
}

@Test
func deleteIsRejectedWhileALeaseIsHeld() async throws {
    let harness = try Harness(outcomes: [validOutcome()])
    defer { harness.remove() }
    await harness.manager.install(modelID)
    let lease = try await harness.manager.acquireLease(modelID)

    await #expect(throws: ModelStoreError(issue: .modelInUse(modelID))) {
        try await harness.manager.delete(modelID)
    }
    #expect(await harness.manager.installedDirectory(for: modelID) != nil)

    await harness.manager.releaseLease(lease)
    try await harness.manager.delete(modelID)
    #expect(await harness.manager.state(for: modelID) == .notInstalled)
}

@Test
func leasingMovesAnInstalledModelToReadyAndBack() async throws {
    let harness = try Harness(outcomes: [validOutcome()])
    defer { harness.remove() }
    await harness.manager.install(modelID)

    let first = try await harness.manager.acquireLease(modelID)
    #expect(await harness.manager.state(for: modelID) == .ready(leaseCount: 1))
    let second = try await harness.manager.acquireLease(modelID)
    #expect(await harness.manager.state(for: modelID) == .ready(leaseCount: 2))

    await harness.manager.releaseLease(second)
    await harness.manager.releaseLease(first)
    #expect(await harness.manager.state(for: modelID) == .installed)
}

@Test
func leasingAnAbsentModelFails() async throws {
    let harness = try Harness(outcomes: [])
    defer { harness.remove() }

    await #expect(throws: ModelStoreError.self) {
        _ = try await harness.manager.acquireLease(modelID)
    }
}

// MARK: - Reconciliation

@Test
func reconcileDropsReceiptsWhoseDirectoryIsGone() async throws {
    let harness = try Harness(outcomes: [validOutcome()])
    defer { harness.remove() }
    await harness.manager.install(modelID)
    let installed = try #require(await harness.manager.installedDirectory(for: modelID))
    try FileManager.default.removeItem(at: installed)

    let reopened = ModelManager(
        layout: harness.layout,
        downloader: harness.downloader,
        catalog: try makeCatalog()
    )

    #expect(await reopened.state(for: modelID) == .notInstalled)
}

@Test
func reconcileDeletesOrphanDirectoriesAndStagingButKeepsQuarantineAndCache() async throws {
    let harness = try Harness(outcomes: [])
    defer { harness.remove() }
    try harness.layout.createBuckets()
    let slug = try #require(ModelStorageSlug("orphan"))
    let orphan = harness.layout.installed(slug)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    let staging = harness.layout.staging(slug, run: UUID())
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let quarantine = harness.layout.quarantine(slug, run: UUID())
    try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
    let cacheEntry = harness.layout.hubCacheRoot.appending(path: "blobs", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: cacheEntry, withIntermediateDirectories: true)

    await harness.manager.reconcile()

    #expect(!FileManager.default.fileExists(atPath: orphan.path), "orphan install survived")
    #expect(!FileManager.default.fileExists(atPath: staging.path), "stale staging survived")
    #expect(FileManager.default.fileExists(atPath: quarantine.path), "quarantine is evidence, keep it")
    #expect(FileManager.default.fileExists(atPath: cacheEntry.path), "cache is resume fuel, keep it")
}

// MARK: - Stream and unknown models

@Test
func stateStreamReplaysTheCurrentSnapshotToALateSubscriber() async throws {
    let harness = try Harness(outcomes: [validOutcome()])
    defer { harness.remove() }
    await harness.manager.install(modelID)

    let stream = await harness.manager.stateStream()
    var iterator = stream.makeAsyncIterator()
    let first = await iterator.next()

    #expect(first?.state(for: modelID) == .installed)
    #expect(first?.state(for: otherID) == .notInstalled)
}

@Test
func installingAnUnknownModelFailsWithoutTouchingTheDownloader() async throws {
    let harness = try Harness(outcomes: [validOutcome()])
    defer { harness.remove() }

    let unknown = ModelID("owner/nope")
    await harness.manager.install(unknown)

    #expect(await harness.manager.state(for: unknown) == .failed(ModelStoreError(issue: .unknownModel(unknown))))
    #expect(harness.downloader.callCount == 0)
}

@Test
func installIsRejectedWhenTheDiskCannotHoldTheModel() async throws {
    let harness = try Harness(outcomes: [validOutcome()], availableBytes: 1)
    defer { harness.remove() }

    await harness.manager.install(modelID)

    if case .failed(let error) = await harness.manager.state(for: modelID) {
        #expect(error.recoveryAction == .freeDiskSpace)
    } else {
        Issue.record("expected a disk space failure")
    }
    #expect(harness.downloader.callCount == 0, "preflight must run before any transfer")
}

@Test
func progressUpdatesAreMonotonicAndStopAtTheFinalState() async throws {
    let harness = try Harness(outcomes: [validOutcome()])
    defer { harness.remove() }

    let recorder = ProgressLog()
    let stream = await harness.manager.stateStream()
    let observer = Task {
        for await snapshot in stream {
            if case .downloading(let completed, let total) = snapshot.state(for: modelID) {
                await recorder.record(completed: completed, total: total)
            }
        }
    }
    defer { observer.cancel() }

    await harness.manager.install(modelID)
    try await eventually { await recorder.count > 0 }

    #expect(await recorder.isMonotonic)
    #expect(await harness.manager.state(for: modelID) == .installed)
}

private actor ProgressLog {
    private var values: [Int64] = []

    var count: Int { values.count }
    var isMonotonic: Bool { zip(values, values.dropFirst()).allSatisfy { $0 <= $1 } }

    func record(completed: Int64, total: Int64) {
        values.append(completed)
    }
}
