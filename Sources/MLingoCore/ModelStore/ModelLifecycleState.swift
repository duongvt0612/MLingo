import Foundation

/// Where a catalog model stands right now.
///
/// Only `installed` and `quarantined` survive a restart; everything else is in-memory. An
/// interrupted download therefore comes back as `notInstalled`, which is honest: no progress was
/// persisted. Completed files do survive in the download cache, so retrying is still cheap.
public enum ModelLifecycleState: Equatable, Sendable {
    case notInstalled
    case probing
    case queued(position: Int)
    case downloading(completedBytes: Int64, totalBytes: Int64)
    case verifying
    case installing
    case installed
    case loading
    case ready(leaseCount: Int)
    case failed(ModelStoreError)
    case cancelled
    case quarantined(reason: ModelQuarantineReason)

    /// Whether the model can be used right now.
    public var isUsable: Bool {
        switch self {
        case .installed, .loading, .ready: true
        default: false
        }
    }

    /// Whether work is under way, so the UI can disable a second Download.
    public var isBusy: Bool {
        switch self {
        case .probing, .queued, .downloading, .verifying, .installing, .loading: true
        default: false
        }
    }

    public var error: ModelStoreError? {
        switch self {
        case .failed(let error): error
        case .quarantined(let reason): ModelStoreError(issue: reason.issue)
        default: nil
        }
    }
}

/// A coalescing view of every catalog model's state.
///
/// Kept free of disk figures on purpose: it is published on every transition and several times a
/// second during a download, and walking the store that often would be wasteful. Call
/// `ModelManager.catalogSnapshot()` when byte counts are actually needed.
public struct ModelStateSnapshot: Equatable, Sendable {
    public let states: [ModelID: ModelLifecycleState]

    public init(states: [ModelID: ModelLifecycleState]) {
        self.states = states
    }

    public func state(for id: ModelID) -> ModelLifecycleState {
        states[id] ?? .notInstalled
    }
}

public struct ModelStatus: Equatable, Sendable {
    public let entry: ModelCatalogEntry
    public let state: ModelLifecycleState
    /// Bytes on disk, present once the model is installed.
    public let installedBytes: UInt64?

    public init(entry: ModelCatalogEntry, state: ModelLifecycleState, installedBytes: UInt64?) {
        self.entry = entry
        self.state = state
        self.installedBytes = installedBytes
    }
}

public struct ModelCatalogSnapshot: Equatable, Sendable {
    public let entries: [ModelStatus]
    public let usage: ModelStorageUsage

    public init(entries: [ModelStatus], usage: ModelStorageUsage) {
        self.entries = entries
        self.usage = usage
    }
}

public extension ModelQuarantineReason {
    /// Restores the issue a persisted quarantine reason stands for, so a model quarantined
    /// before a restart still shows a real message and recovery action.
    var issue: ModelStoreIssue {
        switch self {
        case .missingFile: .missingRequiredFile("a required file")
        case .emptyFile: .emptyFile("a required file")
        case .malformedManifest: .malformedManifest("config.json")
        case .unsafeEntry: .unsafeSnapshotEntry("an unexpected entry")
        case .tooLarge: .snapshotTooLarge(actualBytes: 0, allowedBytes: 0)
        case .digestMismatch: .digestMismatch("a downloaded file")
        }
    }
}
