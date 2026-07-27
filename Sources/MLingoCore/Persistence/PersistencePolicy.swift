import Foundation

public enum PersistenceBackend: String, Sendable {
    case keychain = "Keychain"
    case userDefaults = "UserDefaults"
    case swiftDataDeferred = "SwiftData deferred"
    case fileSystem = "File system"
}

public struct PersistencePolicy: Equatable, Sendable {
    public let name: String
    public let backend: PersistenceBackend
    public let note: String

    public init(name: String, backend: PersistenceBackend, note: String) {
        self.name = name
        self.backend = backend
        self.note = note
    }
}

public enum MLingoPersistencePolicy {
    public static let apiKey = PersistencePolicy(
        name: "OpenAI API key",
        backend: .keychain,
        note: "Sensitive credential. Never store in SwiftData, UserDefaults, logs, or diagnostics."
    )

    public static let preferences = PersistencePolicy(
        name: "Small user preferences",
        backend: .userDefaults,
        note: "Suitable for model names, subtitle appearance, theme, and language pair settings."
    )

    public static let futureUserData = PersistencePolicy(
        name: "Future user data",
        backend: .swiftDataDeferred,
        note: "Reserve SwiftData for future history, vocabulary, or larger user-owned datasets."
    )

    public static let modelAssets = PersistencePolicy(
        name: "Downloaded model assets",
        backend: .fileSystem,
        note: """
        Weights and their install receipts live together under Application Support so a \
        receipt can never describe a folder that moved or was reset independently.
        """
    )

    public static let all: [PersistencePolicy] = [
        apiKey,
        preferences,
        futureUserData,
        modelAssets
    ]
}
