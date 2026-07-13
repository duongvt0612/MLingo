import Foundation

public protocol SettingsStoreProtocol: AnyObject, Sendable {
    func load() async throws -> AppSettings
    func save(_ settings: AppSettings) async throws
}

public protocol APIKeyStoreProtocol: AnyObject, Sendable {
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ apiKey: String) throws
    func deleteAPIKey() throws
}
