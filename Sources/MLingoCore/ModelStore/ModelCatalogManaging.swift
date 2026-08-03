import Foundation

/// Everything the Models pane is allowed to do to the model store.
///
/// `ModelManager` is a concrete actor with no protocol, and reaching it from an app test would
/// mean writing into the real Application Support directory. This is the seam that lets Settings
/// be driven by a fake, and it is deliberately narrower than the actor: leases belong to the
/// runtime, reconciliation happens on first use, and neither is the user's business.
public protocol ModelCatalogManaging: Sendable {
    /// Catalog rows with state and disk figures. Walks the store, so it is called when the numbers
    /// change rather than on every progress tick.
    func catalogSnapshot() async -> ModelCatalogSnapshot

    /// Coalescing state updates. Replays the latest value to a late subscriber.
    func stateStream() async -> AsyncStream<ModelStateSnapshot>

    func install(_ id: ModelID) async

    /// Clears a previous failure or quarantine, then installs again.
    func retry(_ id: ModelID) async

    func cancel(_ id: ModelID) async

    func delete(_ id: ModelID) async throws
}

extension ModelManager: ModelCatalogManaging {}
