import Foundation

/// Logical identifier for a catalog model, for example `mlx-community/whisper-base-mlx`.
///
/// May contain `/` and is therefore never safe to place in a path. `ModelStorageSlug` exists
/// for that; see `ModelStorageLayout`, which accepts only slugs.
public struct ModelID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }
}

extension ModelID: CustomStringConvertible {
    public var description: String { rawValue }
}

/// The only value permitted inside a model storage path.
///
/// Validation is deliberately narrower than the filesystem allows: lowercase alphanumerics,
/// dot, underscore and hyphen, starting with an alphanumeric, at most 64 characters. That
/// excludes `.`, `..`, both separators, NUL, and anything needing escaping. Because
/// `ModelStorageLayout` accepts only this type, a path built from unvalidated input cannot be
/// written — the compiler rejects it rather than a runtime check catching it.
public struct ModelStorageSlug: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init?(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    private static func isValid(_ value: String) -> Bool {
        guard (1...64).contains(value.count) else { return false }
        var isFirst = true
        for character in value.unicodeScalars {
            let isAlphanumeric = ("a"..."z").contains(character) || ("0"..."9").contains(character)
            if isFirst {
                guard isAlphanumeric else { return false }
                isFirst = false
                continue
            }
            guard isAlphanumeric || character == "." || character == "_" || character == "-" else {
                return false
            }
        }
        return true
    }
}

extension ModelStorageSlug: CustomStringConvertible {
    public var description: String { rawValue }
}

/// What a catalog model is for. Selects the manifest rules applied during verification.
public enum ModelRole: String, Codable, CaseIterable, Hashable, Sendable {
    case speechRecognition
    case chat
    case embedding
}
