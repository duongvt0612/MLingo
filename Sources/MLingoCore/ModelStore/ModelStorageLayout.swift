import Foundation

/// The only place model storage URLs are constructed.
///
/// Every accessor takes a `ModelStorageSlug`, so containment inside the store root is a
/// property of the type system rather than of a runtime check. `contains(_:)` exists for the
/// installer to guard destructive operations, where being wrong is expensive.
public struct ModelStorageLayout: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var installedRoot: URL { directory("installed") }
    public var stagingRoot: URL { directory("staging") }
    public var quarantineRoot: URL { directory("quarantine") }

    /// MLingo's own Hugging Face cache. Kept separate from `~/.cache/huggingface` so accounting
    /// stays accurate and no other tool can mutate it behind us.
    public var hubCacheRoot: URL { directory("hub-cache") }

    /// The install receipt index — the only state that survives a restart.
    public var receiptFile: URL {
        root.appending(path: "installed.json", directoryHint: .notDirectory)
    }

    public func installed(_ slug: ModelStorageSlug) -> URL {
        installedRoot.appending(path: slug.rawValue, directoryHint: .isDirectory)
    }

    /// Download target. Tagged with a run identifier so a retry never adopts a previous
    /// attempt's partial directory.
    public func staging(_ slug: ModelStorageSlug, run: UUID) -> URL {
        stagingRoot.appending(path: "\(slug.rawValue)-\(run.uuidString)", directoryHint: .isDirectory)
    }

    /// Where a snapshot that failed verification is kept as evidence.
    public func quarantine(_ slug: ModelStorageSlug, run: UUID) -> URL {
        quarantineRoot.appending(path: "\(slug.rawValue)-\(run.uuidString)", directoryHint: .isDirectory)
    }

    /// Whether `url` resolves to somewhere inside the store. Call before deleting or replacing.
    public func contains(_ url: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        return candidate.hasPrefix(rootPath + "/")
    }

    /// Idempotent; reconciliation calls this on every launch.
    public func createBuckets(fileManager: FileManager = .default) throws {
        for directory in [root, installedRoot, stagingRoot, quarantineRoot, hubCacheRoot] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public static func defaultRoot(fileManager: FileManager = .default) throws -> URL {
        try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appending(path: "MLingo/Models", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    private func directory(_ name: String) -> URL {
        root.appending(path: name, directoryHint: .isDirectory)
    }
}
