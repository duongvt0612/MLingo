import Foundation

/// Why a snapshot was quarantined.
///
/// Deliberately a small, stable enum rather than a persisted `ModelStoreIssue`: the on-disk
/// format should not move every time an error case is renamed, because a failed decode costs
/// the user a re-download.
public enum ModelQuarantineReason: String, Codable, Equatable, Sendable {
    case missingFile
    case emptyFile
    case malformedManifest
    case unsafeEntry
    case tooLarge
    case digestMismatch
}

/// What is on disk for one model. Written after the directory is in place, never before.
public struct ModelInstallReceipt: Codable, Equatable, Sendable {
    public enum Status: Codable, Equatable, Sendable {
        case installed
        case quarantined(reason: ModelQuarantineReason)
    }

    public let modelID: ModelID
    public let slug: ModelStorageSlug
    public let repository: String
    public let revision: String
    public let installedAt: Date
    public let byteCount: UInt64
    public var status: Status

    public init(
        modelID: ModelID,
        slug: ModelStorageSlug,
        repository: String,
        revision: String,
        installedAt: Date,
        byteCount: UInt64,
        status: Status
    ) {
        self.modelID = modelID
        self.slug = slug
        self.repository = repository
        self.revision = revision
        self.installedAt = installedAt
        self.byteCount = byteCount
        self.status = status
    }

    public var isInstalled: Bool {
        status == .installed
    }
}

public struct ModelReceiptIndex: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public private(set) var receipts: [String: ModelInstallReceipt]

    public init(
        schemaVersion: Int = ModelReceiptIndex.currentSchemaVersion,
        receipts: [String: ModelInstallReceipt] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.receipts = receipts
    }

    public func receipt(for id: ModelID) -> ModelInstallReceipt? {
        receipts[id.rawValue]
    }

    public mutating func insert(_ receipt: ModelInstallReceipt) {
        receipts[receipt.modelID.rawValue] = receipt
    }

    public mutating func remove(_ id: ModelID) {
        receipts.removeValue(forKey: id.rawValue)
    }
}

public protocol ModelReceiptStoreProtocol: AnyObject, Sendable {
    func load() async throws -> ModelReceiptIndex
    func save(_ index: ModelReceiptIndex) async throws
}

/// JSON on disk beside the models it describes.
///
/// A damaged or unrecognised index loads as empty and the file is left untouched: the
/// directories it referred to may still be valid, and deciding their fate belongs to
/// reconciliation, not to the reader.
public final class FileModelReceiptStore: ModelReceiptStoreProtocol, @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() async throws -> ModelReceiptIndex {
        lock.withLock {
            guard let data = try? Data(contentsOf: fileURL) else {
                return ModelReceiptIndex()
            }
            guard let index = try? Self.decoder.decode(ModelReceiptIndex.self, from: data) else {
                MLingoLogger.models.warning("Model receipt index could not be decoded; starting empty")
                return ModelReceiptIndex()
            }
            guard index.schemaVersion == ModelReceiptIndex.currentSchemaVersion else {
                MLingoLogger.models.warning(
                    "Model receipt index schema \(index.schemaVersion, privacy: .public) is unsupported"
                )
                return ModelReceiptIndex()
            }
            return index
        }
    }

    public func save(_ index: ModelReceiptIndex) async throws {
        var stored = index
        stored.schemaVersion = ModelReceiptIndex.currentSchemaVersion
        let data = try Self.encoder.encode(stored)
        try lock.withLock {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
        }
    }

    private static let decoder = JSONDecoder()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
