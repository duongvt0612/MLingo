import Foundation

public struct ModelDownloadRequest: Equatable, Sendable {
    public let repository: String
    /// A commit hash, never a branch name. Pinning also lets upstream skip a revision lookup.
    public let revision: String
    /// Exact file names, not globs. See `ModelCatalogEntry.files`.
    public let files: [String]

    public init(repository: String, revision: String, files: [String]) {
        self.repository = repository
        self.revision = revision
        self.files = files
    }

    public init(entry: ModelCatalogEntry) {
        self.init(repository: entry.repository, revision: entry.revision, files: entry.files)
    }
}

public struct ModelDownloadProgress: Equatable, Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64

    public init(completedBytes: Int64, totalBytes: Int64) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    /// Clamped: upstream occasionally reports more bytes than it first advertised, and a
    /// progress bar past 100% reads as a bug.
    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

/// The single seam through which model bytes arrive.
///
/// Narrow on purpose: no `HubClient`, no `Repo.ID`, no Foundation `Progress`. That keeps the
/// default suite offline behind a fake and keeps the main-actor progress contract of the real
/// client from leaking into `ModelManager`.
public protocol ModelSnapshotDownloading: Sendable {
    /// Fetches the requested files and returns the directory holding them.
    ///
    /// Entries in that directory may be symlinks into a shared blob store, so callers must
    /// resolve before reading and must not treat the directory as the install location.
    func downloadSnapshot(
        _ request: ModelDownloadRequest,
        token: String?,
        onProgress: @Sendable @escaping (ModelDownloadProgress) -> Void
    ) async throws -> URL
}
