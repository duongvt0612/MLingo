import Foundation

/// Opaque handle returned by `ModelLeaseRegistry.acquire`. Releasing the same token twice is a
/// no-op, so a `defer` that runs after an error path cannot drive a count negative and let a
/// live model be deleted.
public struct ModelLeaseToken: Hashable, Sendable {
    public let id: UUID
    public let modelID: ModelID

    fileprivate init(modelID: ModelID) {
        id = UUID()
        self.modelID = modelID
    }
}

/// Tracks which installed directories are in use so deletion can refuse.
///
/// This is a different question from the MLX runtime's own lease, which counts weights resident
/// in memory to decide when to unload. Both matter before a delete: this registry says whether
/// anyone still needs the files, and `LocalModelResidencyReporting` says whether the runtime has
/// actually let go of them.
public actor ModelLeaseRegistry {
    private var tokensByModel: [ModelID: Set<UUID>] = [:]

    public init() {}

    @discardableResult
    public func acquire(_ id: ModelID) -> ModelLeaseToken {
        let token = ModelLeaseToken(modelID: id)
        tokensByModel[id, default: []].insert(token.id)
        return token
    }

    public func release(_ token: ModelLeaseToken) {
        guard var tokens = tokensByModel[token.modelID] else { return }
        tokens.remove(token.id)
        if tokens.isEmpty {
            tokensByModel.removeValue(forKey: token.modelID)
        } else {
            tokensByModel[token.modelID] = tokens
        }
    }

    public func count(for id: ModelID) -> Int {
        tokensByModel[id]?.count ?? 0
    }

    public func isLeased(_ id: ModelID) -> Bool {
        count(for: id) > 0
    }

    public var leasedModels: Set<ModelID> {
        Set(tokensByModel.keys)
    }

    public var totalCount: Int {
        tokensByModel.values.reduce(0) { $0 + $1.count }
    }
}
