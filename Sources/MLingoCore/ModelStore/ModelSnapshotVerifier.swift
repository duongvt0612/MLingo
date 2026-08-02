import CryptoKit
import Foundation

/// Checks a freshly downloaded snapshot before it is allowed to become an installation.
///
/// This is the only integrity layer that exists. Upstream stores a file's ETag as its blob name
/// but never compares a hash after transfer, and it can quietly return a stale cached snapshot
/// when a listing request fails — including on 401. So verification always runs, and it runs on
/// the staging directory rather than on whatever the downloader claims to have produced.
///
/// It deliberately never loads MLX: the runtime owns memory residency, and a verifier that
/// instantiated a model would hold weights outside that policy.
///
/// `@unchecked Sendable`: the only shared state is a `FileManager`, which Apple documents as
/// thread-safe for the path-based operations used here. Verification hashes multi-gigabyte
/// weights, so it must be callable off the `ModelManager` actor rather than blocking it.
public struct ModelSnapshotVerifier: @unchecked Sendable {
    /// Guards against a repository that ballooned at a pinned commit.
    public static let sizeTolerance = 0.25
    public static let maximumFileCount = 128

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns the snapshot's total size in bytes.
    @discardableResult
    public func verify(_ directory: URL, against entry: ModelCatalogEntry) throws -> UInt64 {
        let names = try topLevelNames(of: directory)
        try rejectUnsafeEntries(names, in: directory)

        guard names.count <= Self.maximumFileCount else {
            throw ModelStoreError(
                issue: .tooManyFiles(actual: names.count, allowed: Self.maximumFileCount)
            )
        }

        let sizes = try sizesByName(names, in: directory)
        try requireFiles(entry.requiredFiles, from: sizes)
        try requireWeights(in: names)
        try requireParseableConfiguration(in: directory, names: names)
        let totalBytes = sizes.values.reduce(UInt64(0), +)
        try requireSizeWithinTolerance(totalBytes, expected: entry.expectedBytes)
        try requireDigests(entry.expectedDigests, in: directory)

        return totalBytes
    }

    private func topLevelNames(of directory: URL) throws -> [String] {
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ModelStoreError(issue: .storageUnavailable)
        }
        do {
            return try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
        } catch {
            throw ModelStoreError(issue: .storageUnavailable)
        }
    }

    /// Staging is assembled by hardlinking a flat file list, so a symlink or a subdirectory means
    /// something other than the installer wrote here. Both are refused rather than resolved.
    private func rejectUnsafeEntries(_ names: [String], in directory: URL) throws {
        for name in names {
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let type = attributes?[.type] as? FileAttributeType
            guard type == .typeRegular else {
                throw ModelStoreError(issue: .unsafeSnapshotEntry(name))
            }
        }
    }

    private func sizesByName(_ names: [String], in directory: URL) throws -> [String: UInt64] {
        var sizes: [String: UInt64] = [:]
        for name in names {
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            sizes[name] = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        }
        return sizes
    }

    private func requireFiles(_ required: [String], from sizes: [String: UInt64]) throws {
        for name in required {
            guard let size = sizes[name] else {
                throw ModelStoreError(issue: .missingRequiredFile(name))
            }
            guard size > 0 else {
                throw ModelStoreError(issue: .emptyFile(name))
            }
        }
    }

    private func requireWeights(in names: [String]) throws {
        guard names.contains(where: { $0.hasSuffix(".safetensors") }) else {
            throw ModelStoreError(issue: .missingRequiredFile("model.safetensors"))
        }
    }

    /// Only `config.json` is parsed. It is the manifest every loader reads first, and parsing a
    /// multi-megabyte tokenizer on every install would cost more than it catches — an unreadable
    /// tokenizer still fails the non-empty check and then fails loudly at load.
    private func requireParseableConfiguration(in directory: URL, names: [String]) throws {
        guard names.contains("config.json") else { return }
        let url = directory.appending(path: "config.json", directoryHint: .notDirectory)
        guard
            let data = try? Data(contentsOf: url),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        else {
            throw ModelStoreError(issue: .malformedManifest("config.json"))
        }
    }

    private func requireSizeWithinTolerance(_ actual: UInt64, expected: UInt64) throws {
        guard expected > 0 else { return }
        let allowed = expected + UInt64(Double(expected) * Self.sizeTolerance)
        guard actual <= allowed else {
            throw ModelStoreError(issue: .snapshotTooLarge(actualBytes: actual, allowedBytes: allowed))
        }
    }

    private func requireDigests(_ digests: [String: String], in directory: URL) throws {
        for (name, expected) in digests.sorted(by: { $0.key < $1.key }) {
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            guard let actual = try? Self.sha256(of: url), actual == expected.lowercased() else {
                throw ModelStoreError(issue: .digestMismatch(name))
            }
        }
    }

    /// Streamed so a multi-gigabyte weight file never lands in memory.
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public extension ModelQuarantineReason {
    /// Maps a verification failure onto the small, stable reason recorded in the receipt index.
    /// Returns `nil` for issues that are retried rather than quarantined.
    init?(issue: ModelStoreIssue) {
        switch issue {
        case .missingRequiredFile: self = .missingFile
        case .emptyFile: self = .emptyFile
        case .malformedManifest: self = .malformedManifest
        case .unsafeSnapshotEntry: self = .unsafeEntry
        case .snapshotTooLarge, .tooManyFiles: self = .tooLarge
        case .digestMismatch: self = .digestMismatch
        case .unknownModel, .modelNotInstalled, .storageUnavailable, .insufficientDiskSpace, .authenticationRequired,
             .accessGated, .repositoryNotFound, .transportFailure, .installFailed, .modelInUse,
             .refusedOutsideStore:
            return nil
        }
    }
}
