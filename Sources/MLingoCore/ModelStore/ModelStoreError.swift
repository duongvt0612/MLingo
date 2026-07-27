import Foundation

/// Why a model operation could not complete.
///
/// Cases carry a bare file name, never a path: descriptions reach Settings, and an absolute
/// path would expose the account name. `ModelStoreError.errorDescription` reduces whatever it
/// is given to a last path component as a second line of defence.
public enum ModelStoreIssue: Equatable, Sendable {
    case unknownModel(ModelID)
    case storageUnavailable
    case insufficientDiskSpace(requiredBytes: UInt64, availableBytes: UInt64)
    case authenticationRequired
    case accessGated(repository: String)
    case repositoryNotFound(repository: String)
    case transportFailure
    case missingRequiredFile(String)
    case emptyFile(String)
    case malformedManifest(String)
    case unsafeSnapshotEntry(String)
    case snapshotTooLarge(actualBytes: UInt64, allowedBytes: UInt64)
    case digestMismatch(String)
    case installFailed
    case modelInUse(ModelID)
    /// A destructive operation was aimed outside the model store. Always a bug, never input.
    case refusedOutsideStore(String)
}

/// The single next step a user can take. Settings renders one control per action.
public enum ModelStoreRecoveryAction: Equatable, Sendable {
    case retryDownload
    case freeDiskSpace
    case addHuggingFaceToken
    case acceptRepositoryLicence(repository: String)
    case stopActiveSession
    case reinstallModel
    case checkStorageAccess
    case reportBug

    public var title: String {
        switch self {
        case .retryDownload: "Try Again"
        case .freeDiskSpace: "Free Up Space"
        case .addHuggingFaceToken: "Add Hugging Face Token"
        case .acceptRepositoryLicence: "Open Model Page"
        case .stopActiveSession: "Stop Session"
        case .reinstallModel: "Download Again"
        case .checkStorageAccess: "Check Storage"
        case .reportBug: "Report a Problem"
        }
    }
}

public struct ModelStoreError: Error, Equatable, Sendable {
    public let issue: ModelStoreIssue

    public init(issue: ModelStoreIssue) {
        self.issue = issue
    }

    /// Exhaustive by construction: adding an issue without a recovery action will not compile.
    public var recoveryAction: ModelStoreRecoveryAction {
        switch issue {
        case .unknownModel:
            .reportBug
        case .storageUnavailable:
            .checkStorageAccess
        case .insufficientDiskSpace:
            .freeDiskSpace
        case .authenticationRequired:
            .addHuggingFaceToken
        case .accessGated(let repository):
            .acceptRepositoryLicence(repository: repository)
        case .repositoryNotFound:
            .reportBug
        case .transportFailure:
            .retryDownload
        case .missingRequiredFile, .emptyFile, .malformedManifest, .digestMismatch:
            .reinstallModel
        case .unsafeSnapshotEntry, .snapshotTooLarge, .refusedOutsideStore:
            .reportBug
        case .installFailed:
            .retryDownload
        case .modelInUse:
            .stopActiveSession
        }
    }
}

extension ModelStoreError: LocalizedError {
    public var errorDescription: String? {
        switch issue {
        case .unknownModel(let id):
            "\(id.rawValue) is not in the model catalog."
        case .storageUnavailable:
            "MLingo could not open its model storage folder."
        case .insufficientDiskSpace(let required, let available):
            """
            This model needs \(Self.formatted(required)) but only \
            \(Self.formatted(available)) is free.
            """
        case .authenticationRequired:
            "This model requires a Hugging Face token."
        case .accessGated(let repository):
            "\(repository) requires accepting its licence before downloading."
        case .repositoryNotFound(let repository):
            "\(repository) is no longer available at the pinned revision."
        case .transportFailure:
            "The download could not reach Hugging Face."
        case .missingRequiredFile(let name):
            "The download is missing \(Self.fileName(name))."
        case .emptyFile(let name):
            "\(Self.fileName(name)) downloaded as an empty file."
        case .malformedManifest(let name):
            "\(Self.fileName(name)) could not be read."
        case .unsafeSnapshotEntry(let name):
            "The download contains an unsafe entry named \(Self.fileName(name))."
        case .snapshotTooLarge(let actual, let allowed):
            """
            The download is \(Self.formatted(actual)), well beyond the expected \
            \(Self.formatted(allowed)).
            """
        case .digestMismatch(let name):
            "\(Self.fileName(name)) does not match its expected checksum."
        case .installFailed:
            "The model could not be moved into place."
        case .modelInUse(let id):
            "\(id.rawValue) is in use by the current session."
        case .refusedOutsideStore(let name):
            "MLingo refused to modify \(Self.fileName(name)) because it is outside model storage."
        }
    }

    /// Reduces anything path-like to its last component so no description can leak a path.
    private static func fileName(_ value: String) -> String {
        let name = (value as NSString).lastPathComponent
        return name.isEmpty ? "an unnamed file" : name
    }

    private static func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
