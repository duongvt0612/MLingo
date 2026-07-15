import Foundation

public enum OpenAICompatibleAuthApplicator {
    public static func apply(
        authentication: ProviderAuthentication,
        to request: inout URLRequest,
        secretProvider: @Sendable (CredentialID) throws -> String?
    ) throws {
        switch authentication {
        case .none:
            return
        case .bearer(let credentialID):
            let secret = try loadSecret(credentialID: credentialID, secretProvider: secretProvider)
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        case .customHeader(let name, let credentialID):
            let secret = try loadSecret(credentialID: credentialID, secretProvider: secretProvider)
            request.setValue(secret, forHTTPHeaderField: name)
        }
    }

    private static func loadSecret(
        credentialID: CredentialID,
        secretProvider: @Sendable (CredentialID) throws -> String?
    ) throws -> String {
        let secret = try secretProvider(credentialID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let secret, !secret.isEmpty else {
            throw MLingoError.missingAPIKey
        }
        return secret
    }
}
