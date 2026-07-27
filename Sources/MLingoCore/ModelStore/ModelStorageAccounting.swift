import Foundation

public struct ModelStorageUsage: Equatable, Sendable {
    public let installedBytes: UInt64
    public let stagingBytes: UInt64
    public let quarantineBytes: UInt64
    public let hubCacheBytes: UInt64
    /// Bytes held by each installed model, keyed by the directory name under `installed/`.
    public let perModel: [ModelStorageSlug: UInt64]
    /// Actual disk footprint, counting bytes shared between buckets once.
    public let totalBytes: UInt64

    public init(
        installedBytes: UInt64,
        stagingBytes: UInt64,
        quarantineBytes: UInt64,
        hubCacheBytes: UInt64,
        perModel: [ModelStorageSlug: UInt64],
        totalBytes: UInt64
    ) {
        self.installedBytes = installedBytes
        self.stagingBytes = stagingBytes
        self.quarantineBytes = quarantineBytes
        self.hubCacheBytes = hubCacheBytes
        self.perModel = perModel
        self.totalBytes = totalBytes
    }
}

/// Disk usage and the pre-download space check.
///
/// Deliberately limited to disk. Memory is the runtime's business: `BuiltInMLXRuntime` already
/// runs a unified-memory preflight against host availability at load time, and a second opinion
/// here would only produce two answers to one question.
///
/// `@unchecked Sendable` for the `FileManager`, as elsewhere in this module.
public struct ModelStorageAccounting: @unchecked Sendable {
    /// Room left for the operating system after a download. A volume run to the last byte
    /// misbehaves in ways that have nothing to do with models.
    public static let headroomBytes: UInt64 = 256 * 1024 * 1024

    private let layout: ModelStorageLayout
    private let availableBytesProvider: @Sendable () throws -> UInt64
    private let fileManager: FileManager

    public init(
        layout: ModelStorageLayout,
        availableBytes: (@Sendable () throws -> UInt64)? = nil,
        fileManager: FileManager = .default
    ) {
        self.layout = layout
        self.fileManager = fileManager
        let root = layout.root
        // Uses `FileManager.default` rather than the injected instance so the closure stays
        // `@Sendable`; tests that care about the figure inject `availableBytes` instead.
        availableBytesProvider = availableBytes ?? {
            try Self.volumeAvailableBytes(at: root, fileManager: .default)
        }
    }

    /// Per-bucket figures each answer "what does this bucket hold", so they are measured
    /// independently and a hardlinked file legitimately appears in two of them. `totalBytes`
    /// answers "how much disk is this costing" and counts shared bytes once.
    public func usage() throws -> ModelStorageUsage {
        var perModel: [ModelStorageSlug: UInt64] = [:]
        for name in (try? fileManager.contentsOfDirectory(atPath: layout.installedRoot.path)) ?? [] {
            guard let slug = ModelStorageSlug(name) else { continue }
            perModel[slug] = independentSize(of: layout.installed(slug))
        }

        var sharedInodes: Set<UInt64> = []
        let totalBytes = [layout.installedRoot, layout.stagingRoot, layout.quarantineRoot, layout.hubCacheRoot]
            .reduce(UInt64(0)) { $0 + size(of: $1, countedInodes: &sharedInodes) }

        return ModelStorageUsage(
            installedBytes: independentSize(of: layout.installedRoot),
            stagingBytes: independentSize(of: layout.stagingRoot),
            quarantineBytes: independentSize(of: layout.quarantineRoot),
            hubCacheBytes: independentSize(of: layout.hubCacheRoot),
            perModel: perModel,
            totalBytes: totalBytes
        )
    }

    public func availableBytes() throws -> UInt64 {
        try availableBytesProvider()
    }

    /// Rejects a download that would not fit. One copy of the model plus headroom: installation
    /// hardlinks out of the cache rather than copying, so the peak is not twice the model size.
    public func preflight(_ entry: ModelCatalogEntry) throws {
        let required = entry.expectedBytes + Self.headroomBytes
        let available = try availableBytes()
        guard available >= required else {
            throw ModelStoreError(
                issue: .insufficientDiskSpace(requiredBytes: required, availableBytes: available)
            )
        }
    }

    private func independentSize(of directory: URL) -> UInt64 {
        var inodes: Set<UInt64> = []
        return size(of: directory, countedInodes: &inodes)
    }

    /// Sums regular files, skipping anything already seen by inode so a hardlink is charged once.
    private func size(of directory: URL, countedInodes: inout Set<UInt64>) -> UInt64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .fileResourceIdentifierKey]
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        else {
            return 0
        }

        var total: UInt64 = 0
        for case let url as URL in enumerator {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            guard attributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            guard let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value else { continue }
            guard countedInodes.insert(inode).inserted else { continue }
            total += (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        }
        return total
    }

    private static func volumeAvailableBytes(at url: URL, fileManager: FileManager) throws -> UInt64 {
        // Walk up to the nearest existing ancestor: the store may not have been created yet.
        var probe = url
        while !fileManager.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage, capacity > 0 else {
            throw ModelStoreError(issue: .storageUnavailable)
        }
        return UInt64(capacity)
    }
}
