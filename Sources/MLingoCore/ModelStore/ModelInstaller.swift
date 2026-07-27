import Foundation

/// Moves bytes between the download cache, staging, and the installed tree.
///
/// Staging is assembled by hardlinking, not copying. A Hugging Face snapshot directory is
/// symlinks into a shared blob store, and copying would mean holding two full copies of the
/// weights at once. Hardlinks cost nothing, and once the cache entry is dropped the blob's link
/// count falls to one and the bytes live on inside the installation.
///
/// `@unchecked Sendable` for the same reason as `ModelSnapshotVerifier`: the only shared state
/// is a `FileManager`, and installation of a large model should not block the actor.
public struct ModelInstaller: @unchecked Sendable {
    private let layout: ModelStorageLayout
    private let fileManager: FileManager

    public init(layout: ModelStorageLayout, fileManager: FileManager = .default) {
        self.layout = layout
        self.fileManager = fileManager
    }

    /// Links the named files out of a downloaded snapshot into a fresh staging directory.
    ///
    /// Only the listed names are taken, so repository extras and any nested directory are left
    /// behind. A name absent from the snapshot is skipped rather than raising: deciding that a
    /// download is incomplete is verification's job, and it produces a far better message.
    public func stage(snapshot: URL, files: [String], into staging: URL) throws {
        try guardInsideStore(staging)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        for name in files {
            let source = snapshot
                .appending(path: name, directoryHint: .notDirectory)
                .resolvingSymlinksInPath()
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = staging.appending(path: name, directoryHint: .notDirectory)
            do {
                try fileManager.linkItem(at: source, to: destination)
            } catch {
                // Different volume, or a filesystem without hardlinks. Correctness first.
                try fileManager.copyItem(at: source, to: destination)
            }
        }
    }

    /// Swaps a verified staging directory into its installed location.
    ///
    /// `replaceItemAt` when something is already there, so an interrupted upgrade cannot leave a
    /// mixture of two revisions; a plain move otherwise.
    public func install(staging: URL, into installed: URL) throws {
        try guardInsideStore(staging)
        try guardInsideStore(installed)
        do {
            try fileManager.createDirectory(
                at: installed.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: installed.path) {
                _ = try fileManager.replaceItemAt(installed, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: installed)
            }
        } catch let error as ModelStoreError {
            throw error
        } catch {
            MLingoLogger.models.error(
                "Model install failed with code \((error as NSError).code, privacy: .public)"
            )
            throw ModelStoreError(issue: .installFailed)
        }
    }

    /// Keeps a snapshot that failed verification so the user can be told why, and so a bug
    /// report has something to point at. Reconciliation never clears this bucket.
    public func quarantine(staging: URL, into destination: URL) throws {
        try guardInsideStore(staging)
        try guardInsideStore(destination)
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            throw ModelStoreError(issue: .installFailed)
        }
    }

    /// Deletes a directory inside the store.
    ///
    /// Renames into staging first so the model disappears from its published location in one
    /// step; freeing the bytes afterwards can take a while for a multi-gigabyte model. An
    /// already-absent directory is success, because that is the state the caller asked for.
    public func remove(_ url: URL) throws {
        try guardInsideStore(url)
        guard fileManager.fileExists(atPath: url.path) else { return }

        let scratch = layout.stagingRoot
            .appending(path: "removing-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: layout.stagingRoot, withIntermediateDirectories: true)
            try fileManager.moveItem(at: url, to: scratch)
            try fileManager.removeItem(at: scratch)
        } catch {
            try? fileManager.removeItem(at: scratch)
            throw ModelStoreError(issue: .installFailed)
        }
    }

    private func guardInsideStore(_ url: URL) throws {
        guard layout.contains(url) else {
            throw ModelStoreError(issue: .refusedOutsideStore(url.lastPathComponent))
        }
    }
}
