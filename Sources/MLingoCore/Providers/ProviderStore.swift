import Foundation
import Security

public struct ProviderConfiguration: Codable, Equatable, Sendable {
    public var profiles: [ProviderProfile]
    public var selections: [ModelCapability: CapabilitySelection]

    public init(
        profiles: [ProviderProfile] = [],
        selections: [ModelCapability: CapabilitySelection] = [:]
    ) {
        self.profiles = profiles
        self.selections = selections
    }
}

public enum ProviderConfigurationError: Error, Equatable, Sendable {
    case duplicateProfileID(UUID)
    case invalidProfile(UUID, ProviderProfileValidationIssue)
    case invalidSelection(ProviderResolutionError)
    case malformedStorage
}

public protocol ProviderProfileStoreProtocol: AnyObject, Sendable {
    func load() async throws -> ProviderConfiguration
    func save(_ configuration: ProviderConfiguration) async throws
}

public final class UserDefaultsProviderProfileStore: ProviderProfileStoreProtocol,
    @unchecked Sendable
{
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        key: String = "com.duongvt.MLingo.provider-configuration"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() async throws -> ProviderConfiguration {
        try lock.withLock {
            guard let data = defaults.data(forKey: key) else {
                return ProviderConfiguration()
            }
            guard let configuration = try? decoder.decode(
                ProviderConfiguration.self,
                from: data
            ) else {
                throw ProviderConfigurationError.malformedStorage
            }
            try validate(configuration)
            return configuration
        }
    }

    public func save(_ configuration: ProviderConfiguration) async throws {
        try lock.withLock {
            try validate(configuration)
            defaults.set(try encoder.encode(configuration), forKey: key)
        }
    }

    private func validate(_ configuration: ProviderConfiguration) throws {
        var profileIDs: Set<UUID> = []
        for profile in configuration.profiles {
            guard profileIDs.insert(profile.id).inserted else {
                throw ProviderConfigurationError.duplicateProfileID(profile.id)
            }
            if let issue = profile.validationIssues.first {
                throw ProviderConfigurationError.invalidProfile(profile.id, issue)
            }
        }

        let registry = ProviderRegistry(
            profiles: configuration.profiles,
            selections: configuration.selections
        )
        for capability in configuration.selections.keys {
            do {
                _ = try registry.resolve(capability)
            } catch let error as ProviderResolutionError {
                throw ProviderConfigurationError.invalidSelection(error)
            }
        }
    }
}

public protocol ProviderCredentialStoreProtocol: AnyObject, Sendable {
    func loadCredential(for id: CredentialID) throws -> String?
    func saveCredential(_ secret: String, for id: CredentialID) throws
    func deleteCredential(for id: CredentialID) throws
}

public struct ProviderCredentialStoreError: Error, Equatable, Sendable {
    public let operation: CredentialStoreOperation
    public let credentialID: CredentialID
    public let status: Int32

    public init(
        operation: CredentialStoreOperation,
        credentialID: CredentialID,
        status: Int32
    ) {
        self.operation = operation
        self.credentialID = credentialID
        self.status = status
    }
}

public final class KeychainProviderCredentialStore: ProviderCredentialStoreProtocol,
    @unchecked Sendable
{
    private let service: String
    private let client: any KeychainItemClientProtocol

    public convenience init(service: String = "com.duongvt.MLingo.providers") {
        self.init(service: service, client: SystemKeychainItemClient())
    }

    init(service: String, client: any KeychainItemClientProtocol) {
        self.service = service
        self.client = client
    }

    public func loadCredential(for id: CredentialID) throws -> String? {
        switch client.read(service: service, account: id.rawValue) {
        case .notFound:
            return nil
        case .failure(let status):
            throw failure(operation: .load, id: id, status: status)
        case .found(let data):
            guard let secret = String(data: data, encoding: .utf8) else {
                throw failure(operation: .load, id: id, status: errSecDecode)
            }
            return secret
        }
    }

    public func saveCredential(_ secret: String, for id: CredentialID) throws {
        let data = Data(secret.utf8)
        switch client.read(service: service, account: id.rawValue) {
        case .found:
            let status = client.update(data, service: service, account: id.rawValue)
            if status == errSecItemNotFound {
                try add(data, id: id)
            } else if status != errSecSuccess {
                throw failure(operation: .update, id: id, status: status)
            }
        case .notFound:
            let status = client.add(data, service: service, account: id.rawValue)
            if status == errSecDuplicateItem {
                let fallback = client.update(data, service: service, account: id.rawValue)
                guard fallback == errSecSuccess else {
                    throw failure(operation: .update, id: id, status: fallback)
                }
            } else if status != errSecSuccess {
                throw failure(operation: .add, id: id, status: status)
            }
        case .failure(let status):
            throw failure(operation: .inspect, id: id, status: status)
        }
    }

    public func deleteCredential(for id: CredentialID) throws {
        let status = client.delete(service: service, account: id.rawValue)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw failure(operation: .delete, id: id, status: status)
        }
    }

    private func add(_ data: Data, id: CredentialID) throws {
        let status = client.add(data, service: service, account: id.rawValue)
        guard status == errSecSuccess else {
            throw failure(operation: .add, id: id, status: status)
        }
    }

    private func failure(
        operation: CredentialStoreOperation,
        id: CredentialID,
        status: OSStatus
    ) -> ProviderCredentialStoreError {
        MLingoLogger.settings.error(
            "Provider Keychain operation=\(operation.rawValue, privacy: .public) status=\(status)"
        )
        return ProviderCredentialStoreError(
            operation: operation,
            credentialID: id,
            status: status
        )
    }
}
