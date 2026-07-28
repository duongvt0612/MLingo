import Foundation

/// Lets an engine ask where an installed model lives without knowing anything about the store.
///
/// One function on purpose. `WhisperEngineProtocol.loadModel(named:)` has eleven implementations
/// across the sources and tests, so changing it to take a URL would ripple through the suite for
/// no benefit. Instead the identifier stays a string and only its resolution changes: when this
/// returns a directory the engine loads from disk, and when it returns `nil` the engine falls
/// back to whatever it did before.
public protocol ModelDirectoryResolving: Sendable {
    /// The installed directory for `id`, or `nil` if it is not installed.
    func installedDirectory(forModelID id: String) async -> URL?
}

extension ModelManager: ModelDirectoryResolving {
    public func installedDirectory(forModelID id: String) async -> URL? {
        await installedDirectory(for: ModelID(id))
    }
}
