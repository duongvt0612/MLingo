import Foundation
import Security

public final class KeychainAPIKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "com.duongvt.MLingo", account: String = "openai-api-key") {
        self.service = service
        self.account = account
    }

    public func loadAPIKey() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw MLingoError.translationFailed("Unable to read API key from Keychain: \(status).")
        }

        guard
            let data = result as? Data,
            let key = String(data: data, encoding: .utf8)
        else {
            throw MLingoError.invalidResponse
        }

        return key
    }

    public func saveAPIKey(_ apiKey: String) throws {
        let data = Data(apiKey.utf8)
        var query = baseQuery()

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attributes = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw MLingoError.translationFailed("Unable to update API key in Keychain: \(updateStatus).")
            }
            return
        }

        query[kSecValueData as String] = data
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MLingoError.translationFailed("Unable to save API key in Keychain: \(addStatus).")
        }
    }

    public func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MLingoError.translationFailed("Unable to delete API key from Keychain: \(status).")
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
