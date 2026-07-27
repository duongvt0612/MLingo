import Foundation

/// Owns the lifecycle of every catalog model: probe, download, verify, install, lease, delete.
///
/// One download runs at a time. Model files are large, and several concurrent transfers make
/// each one slower, the progress harder to read, and the disk preflight meaningless.
///
/// Every dependency arrives through the initializer and `shared` deliberately does not exist
/// here. A test that reached a process-wide instance would write into the real Application
/// Support directory and leak state into the next run — `--no-parallel` orders tests within a
/// run, it does not clean up after one.
public actor ModelManager {
    public static let huggingFaceCredentialID = CredentialID("huggingface-token")

    private let layout: ModelStorageLayout
    private let downloader: any ModelSnapshotDownloading
    private let credentialStore: (any ProviderCredentialStoreProtocol)?
    private let receiptStore: any ModelReceiptStoreProtocol
    private let catalog: [ModelCatalogEntry]
    private let verifier: ModelSnapshotVerifier
    private let installer: ModelInstaller
    private let accounting: ModelStorageAccounting
    private let leases: ModelLeaseRegistry
    private let credentialID: CredentialID
    private let progressThrottle: Duration

    private var index = ModelReceiptIndex()
    private var states: [ModelID: ModelLifecycleState] = [:]
    private var activeTasks: [ModelID: Task<Void, Never>] = [:]
    /// Identifies the current attempt so a late progress callback cannot revive a finished run.
    private var currentRun: [ModelID: UUID] = [:]
    private var lastProgressAt: [ModelID: ContinuousClock.Instant] = [:]
    private var readyTask: Task<Void, Never>?

    private var running: ModelID?
    private var waiting: [ModelID] = []
    private var waiters: [ModelID: CheckedContinuation<Void, any Error>] = [:]

    private var streams: [UUID: AsyncStream<ModelStateSnapshot>.Continuation] = [:]

    public init(
        layout: ModelStorageLayout,
        downloader: any ModelSnapshotDownloading,
        catalog: [ModelCatalogEntry] = MLingoModelCatalog.v1,
        credentialStore: (any ProviderCredentialStoreProtocol)? = nil,
        receiptStore: (any ModelReceiptStoreProtocol)? = nil,
        verifier: ModelSnapshotVerifier = ModelSnapshotVerifier(),
        installer: ModelInstaller? = nil,
        accounting: ModelStorageAccounting? = nil,
        leases: ModelLeaseRegistry = ModelLeaseRegistry(),
        credentialID: CredentialID = ModelManager.huggingFaceCredentialID,
        progressThrottle: Duration = .milliseconds(250)
    ) {
        self.layout = layout
        self.downloader = downloader
        self.catalog = catalog
        self.credentialStore = credentialStore
        self.receiptStore = receiptStore ?? FileModelReceiptStore(fileURL: layout.receiptFile)
        self.verifier = verifier
        self.installer = installer ?? ModelInstaller(layout: layout)
        self.accounting = accounting ?? ModelStorageAccounting(layout: layout)
        self.leases = leases
        self.credentialID = credentialID
        self.progressThrottle = progressThrottle
    }

    // MARK: - Queries

    public func state(for id: ModelID) async -> ModelLifecycleState {
        await ensureReady()
        return states[id] ?? .notInstalled
    }

    public func snapshot() async -> ModelStateSnapshot {
        await ensureReady()
        return currentSnapshot()
    }

    /// Adds disk figures, which means walking the store. Call it when the numbers are needed,
    /// not on every state change.
    public func catalogSnapshot() async -> ModelCatalogSnapshot {
        await ensureReady()
        let usage = (try? accounting.usage()) ?? ModelStorageUsage(
            installedBytes: 0, stagingBytes: 0, quarantineBytes: 0, hubCacheBytes: 0,
            perModel: [:], totalBytes: 0
        )
        let entries = catalog.map { entry in
            ModelStatus(
                entry: entry,
                state: states[entry.id] ?? .notInstalled,
                installedBytes: usage.perModel[entry.slug]
            )
        }
        return ModelCatalogSnapshot(entries: entries, usage: usage)
    }

    /// The directory to hand an engine, or `nil` when the model is not installed.
    public func installedDirectory(for id: ModelID) async -> URL? {
        await ensureReady()
        guard let receipt = index.receipt(for: id), receipt.isInstalled else { return nil }
        let directory = layout.installed(receipt.slug)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    /// Bounded at 64: enough to follow a full lifecycle, small enough that a stalled consumer
    /// cannot grow without limit. Under pressure the oldest states are dropped, never the newest.
    public func stateStream() async -> AsyncStream<ModelStateSnapshot> {
        await ensureReady()
        let id = UUID()
        let (stream, continuation) = AsyncStream<ModelStateSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        streams[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStream(id) }
        }
        continuation.yield(currentSnapshot())
        return stream
    }

    // MARK: - Commands

    public func install(_ id: ModelID) async {
        await ensureReady()
        await task(for: id).value
    }

    /// Clears a previous failure or quarantine, then installs again.
    public func retry(_ id: ModelID) async {
        await ensureReady()
        await clearQuarantine(for: id)
        await install(id)
    }

    public func cancel(_ id: ModelID) {
        activeTasks[id]?.cancel()
        if let position = waiting.firstIndex(of: id) {
            waiting.remove(at: position)
            waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            publishQueuePositions()
        }
    }

    public func delete(_ id: ModelID) async throws {
        await ensureReady()
        guard await leases.isLeased(id) == false else {
            throw ModelStoreError(issue: .modelInUse(id))
        }
        guard let receipt = index.receipt(for: id) else { return }

        // Receipt first: a directory with no receipt is an orphan reconciliation can clear, while
        // a receipt with no directory would hand out a path to nothing.
        index.remove(id)
        try? await receiptStore.save(index)
        try installer.remove(layout.installed(receipt.slug))
        update(id, to: .notInstalled)
    }

    public func acquireLease(_ id: ModelID) async throws -> ModelLeaseToken {
        await ensureReady()
        guard await installedDirectory(for: id) != nil else {
            throw ModelStoreError(issue: .modelNotInstalled(id))
        }
        let token = await leases.acquire(id)
        update(id, to: .ready(leaseCount: await leases.count(for: id)))
        return token
    }

    public func releaseLease(_ token: ModelLeaseToken) async {
        await leases.release(token)
        let remaining = await leases.count(for: token.modelID)
        update(token.modelID, to: remaining > 0 ? .ready(leaseCount: remaining) : .installed)
    }

    /// Brings in-memory state back in line with what is actually on disk. Runs once on first use
    /// and is safe to call again.
    public func reconcile() async {
        await ensureReady()
    }

    // MARK: - Reconciliation

    private func ensureReady() async {
        if let readyTask {
            await readyTask.value
            return
        }
        let task = Task { await self.performReconcile() }
        readyTask = task
        await task.value
    }

    private func performReconcile() async {
        try? layout.createBuckets()
        index = (try? await receiptStore.load()) ?? ModelReceiptIndex()

        var changed = false
        for receipt in index.receipts.values where receipt.isInstalled {
            let directory = layout.installed(receipt.slug)
            if !FileManager.default.fileExists(atPath: directory.path) {
                index.remove(receipt.modelID)
                changed = true
            }
        }

        // A directory nobody claims is left over from an interrupted install. The name is used
        // as-is rather than being re-parsed into a slug: an entry whose name is not a valid slug
        // is exactly the kind of stray this is meant to clear, and the installer refuses anything
        // that resolves outside the store.
        let claimed = Set(index.receipts.values.filter(\.isInstalled).map(\.slug.rawValue))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: layout.installedRoot.path)) ?? []
        where !claimed.contains(name) {
            let orphan = layout.installedRoot.appending(path: name, directoryHint: .isDirectory)
            try? installer.remove(orphan)
        }

        // Staging never survives a process: no download resumes across a launch.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: layout.stagingRoot.path)) ?? [] {
            try? FileManager.default.removeItem(
                at: layout.stagingRoot.appending(path: name, directoryHint: .isDirectory)
            )
        }
        // Quarantine stays as evidence for the user; the cache stays because completed files in
        // it are what makes a retry cheap.

        if changed {
            try? await receiptStore.save(index)
        }

        states = [:]
        for entry in catalog {
            states[entry.id] = initialState(for: entry)
        }
        publish()
    }

    private func initialState(for entry: ModelCatalogEntry) -> ModelLifecycleState {
        guard let receipt = index.receipt(for: entry.id) else { return .notInstalled }
        switch receipt.status {
        case .installed:
            return .installed
        case .quarantined(let reason):
            return .quarantined(reason: reason)
        }
    }

    // MARK: - Install pipeline

    private func task(for id: ModelID) -> Task<Void, Never> {
        if let existing = activeTasks[id] { return existing }
        let task = Task { await self.runInstall(id) }
        activeTasks[id] = task
        return task
    }

    private func runInstall(_ id: ModelID) async {
        defer { activeTasks[id] = nil }

        update(id, to: .probing)
        guard let entry = catalog.first(where: { $0.id == id }) else {
            update(id, to: .failed(ModelStoreError(issue: .unknownModel(id))))
            return
        }

        do {
            try accounting.preflight(entry)
            try await acquireSlot(id)
        } catch let error as ModelStoreError {
            update(id, to: .failed(error))
            return
        } catch {
            update(id, to: .cancelled)
            return
        }
        defer { releaseSlot() }

        let run = UUID()
        currentRun[id] = run
        let staging = layout.staging(entry.slug, run: run)

        do {
            try await performInstall(entry, run: run, staging: staging)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: staging)
            update(id, to: .cancelled)
        } catch let error as ModelStoreError {
            await handleFailure(error, entry: entry, run: run, staging: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            MLingoLogger.models.error(
                "Download failed for \(entry.slug.rawValue, privacy: .public) with code \((error as NSError).code, privacy: .public)"
            )
            update(id, to: .failed(ModelStoreError(issue: .transportFailure)))
        }
        currentRun[id] = nil
    }

    private func performInstall(_ entry: ModelCatalogEntry, run: UUID, staging: URL) async throws {
        update(entry.id, to: .downloading(completedBytes: 0, totalBytes: Int64(entry.expectedBytes)))

        let token = huggingFaceToken()
        let snapshot = try await downloader.downloadSnapshot(
            ModelDownloadRequest(entry: entry),
            token: token
        ) { [weak self] progress in
            Task { await self?.recordProgress(entry.id, run: run, progress: progress) }
        }
        try Task.checkCancellation()

        update(entry.id, to: .verifying)
        try installer.stage(snapshot: snapshot, files: entry.files, into: staging)
        // The downloader's return value is not trusted: upstream falls back to a cached snapshot
        // when a listing request fails, including on 401, and reports success either way.
        let byteCount = try verifier.verify(staging, against: entry)
        try Task.checkCancellation()

        update(entry.id, to: .installing)
        try installer.install(staging: staging, into: layout.installed(entry.slug))

        index.insert(
            ModelInstallReceipt(
                modelID: entry.id,
                slug: entry.slug,
                repository: entry.repository,
                revision: entry.revision,
                installedAt: Date(),
                byteCount: byteCount,
                status: .installed
            )
        )
        try? await receiptStore.save(index)
        purgeCacheEntry(for: entry)
        update(entry.id, to: .installed)
        MLingoLogger.models.info(
            "Installed \(entry.slug.rawValue, privacy: .public) at \(entry.revision, privacy: .public)"
        )
    }

    private func handleFailure(
        _ error: ModelStoreError,
        entry: ModelCatalogEntry,
        run: UUID,
        staging: URL
    ) async {
        guard let reason = ModelQuarantineReason(issue: error.issue) else {
            try? FileManager.default.removeItem(at: staging)
            update(entry.id, to: .failed(error))
            return
        }

        // A snapshot that failed verification is kept so the user can be told what was wrong.
        let destination = layout.quarantine(entry.slug, run: run)
        try? installer.quarantine(staging: staging, into: destination)
        index.insert(
            ModelInstallReceipt(
                modelID: entry.id,
                slug: entry.slug,
                repository: entry.repository,
                revision: entry.revision,
                installedAt: Date(),
                byteCount: 0,
                status: .quarantined(reason: reason)
            )
        )
        try? await receiptStore.save(index)
        update(entry.id, to: .quarantined(reason: reason))
        MLingoLogger.models.warning(
            "Quarantined \(entry.slug.rawValue, privacy: .public): \(reason.rawValue, privacy: .public)"
        )
    }

    private func clearQuarantine(for id: ModelID) async {
        guard let receipt = index.receipt(for: id), !receipt.isInstalled else { return }
        index.remove(id)
        let prefix = "\(receipt.slug.rawValue)-"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: layout.quarantineRoot.path)) ?? []
        where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(
                at: layout.quarantineRoot.appending(path: name, directoryHint: .isDirectory)
            )
        }
        try? await receiptStore.save(index)
        update(id, to: .notInstalled)
    }

    /// Drops the cache copy once the bytes are hardlinked into the installation, so the model is
    /// charged to disk once rather than twice.
    private func purgeCacheEntry(for entry: ModelCatalogEntry) {
        let name = "models--" + entry.repository.replacingOccurrences(of: "/", with: "--")
        try? installer.remove(layout.hubCacheRoot.appending(path: name, directoryHint: .isDirectory))
    }

    private func huggingFaceToken() -> String? {
        guard let credentialStore else { return nil }
        return try? credentialStore.loadCredential(for: credentialID)
    }

    // MARK: - Progress

    /// Late, out-of-order, and stale callbacks are all expected: the real client reports progress
    /// on the main actor while this runs on its own, so every update hops queues.
    private func recordProgress(_ id: ModelID, run: UUID, progress: ModelDownloadProgress) {
        guard currentRun[id] == run else { return }
        guard case .downloading(let completed, _) = states[id] else { return }
        guard progress.completedBytes >= completed else { return }

        let now = ContinuousClock.now
        if let last = lastProgressAt[id], now - last < progressThrottle, progress.fraction < 1 {
            return
        }
        lastProgressAt[id] = now
        update(
            id,
            to: .downloading(completedBytes: progress.completedBytes, totalBytes: progress.totalBytes)
        )
    }

    // MARK: - Queue

    private func acquireSlot(_ id: ModelID) async throws {
        try Task.checkCancellation()
        if running == nil, waiting.isEmpty {
            running = id
            return
        }
        waiting.append(id)
        publishQueuePositions()
        try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
        }
    }

    private func releaseSlot() {
        running = nil
        guard !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        running = next
        waiters.removeValue(forKey: next)?.resume()
        publishQueuePositions()
    }

    private func publishQueuePositions() {
        for (offset, id) in waiting.enumerated() {
            states[id] = .queued(position: offset + 1)
        }
        publish()
    }

    // MARK: - Publication

    private func update(_ id: ModelID, to state: ModelLifecycleState) {
        guard states[id] != state else { return }
        states[id] = state
        publish()
    }

    private func currentSnapshot() -> ModelStateSnapshot {
        ModelStateSnapshot(states: states)
    }

    private func publish() {
        let snapshot = currentSnapshot()
        for continuation in streams.values {
            continuation.yield(snapshot)
        }
    }

    private func removeStream(_ id: UUID) {
        streams.removeValue(forKey: id)
    }
}
