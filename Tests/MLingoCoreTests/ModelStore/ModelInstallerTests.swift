import Foundation
import Testing
@testable import MLingoCore

private func inode(of url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
}

private func write(_ name: String, _ contents: String, in directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: name, directoryHint: .notDirectory)
    try Data(contents.utf8).write(to: url, options: [.atomic])
    return url
}

/// Builds a cache-shaped snapshot: real bytes in `blobs`, symlinks in `snapshots`.
private func makeCacheSnapshot(in root: URL, files: [String: String]) throws -> URL {
    let blobs = root.appending(path: "blobs", directoryHint: .isDirectory)
    let snapshot = root.appending(path: "snapshots/abc", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    for (name, contents) in files {
        let blob = try write("blob-\(name)", contents, in: blobs)
        try FileManager.default.createSymbolicLink(
            at: snapshot.appending(path: name, directoryHint: .notDirectory),
            withDestinationURL: blob
        )
    }
    return snapshot
}

private func makeLayout(_ temporary: TemporaryDirectory) throws -> ModelStorageLayout {
    let layout = ModelStorageLayout(root: temporary.appending("Models", isDirectory: true))
    try layout.createBuckets()
    return layout
}

@Test
func installerHardlinksSnapshotEntriesWithoutDuplicatingBytes() throws {
    let temporary = try TemporaryDirectory(label: "Install")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)
    let slug = try #require(ModelStorageSlug("model"))
    let snapshot = try makeCacheSnapshot(
        in: temporary.appending("cache", isDirectory: true),
        files: ["config.json": "{}", "model.safetensors": "weights"]
    )
    let staging = layout.staging(slug, run: UUID())

    try ModelInstaller(layout: layout).stage(
        snapshot: snapshot,
        files: ["config.json", "model.safetensors"],
        into: staging
    )

    // Same inode as the blob means no second copy of the weights on disk.
    for name in ["config.json", "model.safetensors"] {
        let staged = staging.appending(path: name, directoryHint: .notDirectory)
        let blob = snapshot.appending(path: name, directoryHint: .notDirectory).resolvingSymlinksInPath()
        #expect(try inode(of: staged) == (try inode(of: blob)))
        let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular, "\(name) must not stay a symlink")
    }
}

@Test
func installerStagesOnlyTheRequestedFiles() throws {
    let temporary = try TemporaryDirectory(label: "Install")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)
    let slug = try #require(ModelStorageSlug("model"))
    let snapshot = try makeCacheSnapshot(
        in: temporary.appending("cache", isDirectory: true),
        files: ["config.json": "{}", "README.md": "docs", "model.safetensors": "w"]
    )
    let staging = layout.staging(slug, run: UUID())

    // A file missing from the snapshot is tolerated here; verification is what rejects it.
    try ModelInstaller(layout: layout).stage(
        snapshot: snapshot,
        files: ["config.json", "model.safetensors", "absent.json"],
        into: staging
    )

    let staged = try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted()
    #expect(staged == ["config.json", "model.safetensors"])
}

@Test
func installerMovesStagingIntoPlaceWhenNothingIsInstalled() throws {
    let temporary = try TemporaryDirectory(label: "Install")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)
    let slug = try #require(ModelStorageSlug("model"))
    let staging = layout.staging(slug, run: UUID())
    _ = try write("config.json", "{}", in: staging)

    try ModelInstaller(layout: layout).install(staging: staging, into: layout.installed(slug))

    #expect(FileManager.default.fileExists(atPath: layout.installed(slug).appending(path: "config.json").path))
    #expect(!FileManager.default.fileExists(atPath: staging.path))
}

@Test
func installerReplacesAnExistingInstalledDirectoryAtomically() throws {
    let temporary = try TemporaryDirectory(label: "Install")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)
    let slug = try #require(ModelStorageSlug("model"))
    _ = try write("old-only.json", "old", in: layout.installed(slug))
    _ = try write("config.json", "old", in: layout.installed(slug))

    let staging = layout.staging(slug, run: UUID())
    _ = try write("config.json", "new", in: staging)

    try ModelInstaller(layout: layout).install(staging: staging, into: layout.installed(slug))

    let installed = try FileManager.default.contentsOfDirectory(atPath: layout.installed(slug).path).sorted()
    #expect(installed == ["config.json"], "the previous revision must not survive alongside the new one")
    let contents = try String(contentsOf: layout.installed(slug).appending(path: "config.json"), encoding: .utf8)
    #expect(contents == "new")
}

@Test
func installerLeavesTheExistingInstallIntactWhenReplacementFails() throws {
    let temporary = try TemporaryDirectory(label: "Install")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)
    let slug = try #require(ModelStorageSlug("model"))
    _ = try write("config.json", "old", in: layout.installed(slug))
    let staging = layout.staging(slug, run: UUID())
    _ = try write("config.json", "new", in: staging)

    // Injected rather than provoked with a read-only directory: root ignores POSIX permissions, so
    // a chmod-based setup would silently stop testing anything in a container that runs as root.
    let installer = ModelInstaller(layout: layout, fileManager: FailingReplacementFileManager())

    #expect {
        try installer.install(staging: staging, into: layout.installed(slug))
    } throws: { error in
        (error as? ModelStoreError)?.issue == .installFailed
    }

    let contents = try String(contentsOf: layout.installed(slug).appending(path: "config.json"), encoding: .utf8)
    #expect(contents == "old", "a failed install must not leave the model half replaced")
    #expect(FileManager.default.fileExists(atPath: staging.appending(path: "config.json").path))
}

/// Fails only the atomic replacement, leaving every other file operation real.
///
/// `replaceItemAt` is a Swift extension and cannot be overridden, so the Objective-C method it
/// wraps is the injection point.
private final class FailingReplacementFileManager: FileManager, @unchecked Sendable {
    override func replaceItem(
        at originalItemURL: URL,
        withItemAt newItemURL: URL,
        backupItemName: String?,
        options: FileManager.ItemReplacementOptions = [],
        resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

@Test
func installerMovesAFailedSnapshotIntoQuarantine() throws {
    let temporary = try TemporaryDirectory(label: "Install")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)
    let slug = try #require(ModelStorageSlug("model"))
    let run = UUID()
    let staging = layout.staging(slug, run: run)
    _ = try write("config.json", "broken", in: staging)

    let destination = layout.quarantine(slug, run: run)
    try ModelInstaller(layout: layout).quarantine(staging: staging, into: destination)

    #expect(FileManager.default.fileExists(atPath: destination.appending(path: "config.json").path))
    #expect(!FileManager.default.fileExists(atPath: staging.path))
}

@Test
func installerRemovesADirectoryCompletely() throws {
    let temporary = try TemporaryDirectory(label: "Install")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)
    let slug = try #require(ModelStorageSlug("model"))
    _ = try write("config.json", "{}", in: layout.installed(slug))

    try ModelInstaller(layout: layout).remove(layout.installed(slug))

    #expect(!FileManager.default.fileExists(atPath: layout.installed(slug).path))
    // Removal renames into staging first, so nothing may be left lying around there either.
    let staged = try FileManager.default.contentsOfDirectory(atPath: layout.stagingRoot.path)
    #expect(staged.isEmpty, "unexpected leftovers: \(staged)")
}

@Test
func installerTreatsRemovingAnAbsentDirectoryAsSuccess() throws {
    let temporary = try TemporaryDirectory(label: "Install")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)
    let slug = try #require(ModelStorageSlug("model"))

    // Reconciliation removes whatever a stale receipt named; absence is the desired end state.
    try ModelInstaller(layout: layout).remove(layout.installed(slug))
}

@Test
func installerRefusesToRemoveAnythingOutsideTheStore() throws {
    let temporary = try TemporaryDirectory(label: "Install")
    defer { temporary.remove() }
    let layout = try makeLayout(temporary)
    let outsider = temporary.appending("precious", isDirectory: true)
    _ = try write("keep.txt", "important", in: outsider)

    #expect {
        try ModelInstaller(layout: layout).remove(outsider)
    } throws: { error in
        (error as? ModelStoreError)?.issue == .refusedOutsideStore("precious")
    }
    #expect(FileManager.default.fileExists(atPath: outsider.appending(path: "keep.txt").path))
}
