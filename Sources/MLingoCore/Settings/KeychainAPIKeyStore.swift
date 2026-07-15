import Foundation
import Security

enum KeychainItemReadResult: Equatable, Sendable {
    case found(Data)
    case notFound
    case failure(OSStatus)
}

protocol KeychainItemClientProtocol: Sendable {
    func read(service: String, account: String) -> KeychainItemReadResult
    func add(_ data: Data, service: String, account: String) -> OSStatus
    func update(_ data: Data, service: String, account: String) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

struct SystemKeychainItemClient: KeychainItemClientProtocol {
    func read(service: String, account: String) -> KeychainItemReadResult {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failure(errSecDecode) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failure(status)
        }
    }

    func add(_ data: Data, service: String, account: String) -> OSStatus {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil)
    }

    func update(_ data: Data, service: String, account: String) -> OSStatus {
        let query = baseQuery(service: service, account: account)
        let attributes = [kSecValueData as String: data]
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public final class KeychainAPIKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    private let service: String
    private let account: String
    private let client: any KeychainItemClientProtocol

    public convenience init(
        service: String = "com.duongvt.MLingo",
        account: String = "openai-api-key"
    ) {
        self.init(
            service: service,
            account: account,
            client: SystemKeychainItemClient()
        )
    }

    init(
        service: String,
        account: String,
        client: any KeychainItemClientProtocol
    ) {
        self.service = service
        self.account = account
        self.client = client
    }

    public func loadAPIKey() throws -> String? {
        switch client.read(service: service, account: account) {
        case .notFound:
            return nil
        case .failure(let status):
            throw failure(operation: .load, status: status)
        case .found(let data):
            guard let key = String(data: data, encoding: .utf8) else {
                throw failure(operation: .load, status: errSecDecode)
            }
            return key
        }
    }

    public func saveAPIKey(_ apiKey: String) throws {
        let data = Data(apiKey.utf8)
        switch client.read(service: service, account: account) {
        case .found:
            let status = client.update(data, service: service, account: account)
            guard status == errSecSuccess else {
                throw failure(operation: .update, status: status)
            }
        case .notFound:
            let status = client.add(data, service: service, account: account)
            guard status == errSecSuccess else {
                throw failure(operation: .add, status: status)
            }
        case .failure(let status):
            throw failure(operation: .inspect, status: status)
        }
    }

    public func deleteAPIKey() throws {
        let status = client.delete(service: service, account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw failure(operation: .delete, status: status)
        }
    }

    private func failure(
        operation: CredentialStoreOperation,
        status: OSStatus
    ) -> MLingoError {
        MLingoLogger.settings.error(
            "Keychain operation=\(operation.rawValue, privacy: .public) status=\(status)"
        )
        return .credentialStoreFailure(operation: operation, status: status)
    }
}
