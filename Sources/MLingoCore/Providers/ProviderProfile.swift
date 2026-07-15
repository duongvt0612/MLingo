import Foundation

public struct CredentialID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }
}

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case openAI
    case ollama
    case lmStudio
    case custom
    case builtInMLX
    case system

    var requiresEndpoint: Bool {
        switch self {
        case .openAI, .ollama, .lmStudio, .custom:
            true
        case .builtInMLX, .system:
            false
        }
    }
}

public enum ProviderAPIStyle: String, Codable, CaseIterable, Sendable {
    case responses
    case chatCompletions
    case native
}

public enum ProviderAuthentication: Codable, Equatable, Sendable {
    case none
    case bearer(credentialID: CredentialID)
    case customHeader(name: String, credentialID: CredentialID)
}

public enum ProviderProfileValidationIssue: Equatable, Sendable {
    case emptyName
    case missingEndpoint
    case unsupportedEndpointScheme
    case remoteEndpointRequiresHTTPS
    case invalidCustomHeaderName
    case emptyCredentialID
}

public struct ProviderProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: ProviderKind
    public var endpoint: URL?
    public var apiStyle: ProviderAPIStyle
    public var authentication: ProviderAuthentication
    public var models: [ModelCapability: [String]]

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind,
        endpoint: URL?,
        apiStyle: ProviderAPIStyle,
        authentication: ProviderAuthentication,
        models: [ModelCapability: [String]]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endpoint = endpoint
        self.apiStyle = apiStyle
        self.authentication = authentication
        self.models = models
    }

    public var validationIssues: [ProviderProfileValidationIssue] {
        var issues: [ProviderProfileValidationIssue] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyName)
        }
        if kind.requiresEndpoint {
            validateEndpoint(into: &issues)
        }
        validateAuthentication(into: &issues)
        return issues
    }

    private func validateEndpoint(into issues: inout [ProviderProfileValidationIssue]) {
        guard let endpoint else {
            issues.append(.missingEndpoint)
            return
        }
        let scheme = endpoint.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else {
            issues.append(.unsupportedEndpointScheme)
            return
        }
        if scheme == "http", !endpoint.isLoopbackURL {
            issues.append(.remoteEndpointRequiresHTTPS)
        }
    }

    private func validateAuthentication(
        into issues: inout [ProviderProfileValidationIssue]
    ) {
        switch authentication {
        case .none:
            return
        case .bearer(let credentialID):
            if credentialID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.emptyCredentialID)
            }
        case .customHeader(let name, let credentialID):
            if !name.isValidHTTPHeaderName {
                issues.append(.invalidCustomHeaderName)
            }
            if credentialID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.emptyCredentialID)
            }
        }
    }
}

private extension URL {
    var isLoopbackURL: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host == "[::1]"
    }
}

private extension String {
    var isValidHTTPHeaderName: Bool {
        guard !isEmpty else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"
        )
        return unicodeScalars.allSatisfy(allowed.contains)
    }
}
