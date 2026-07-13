import Foundation

public enum MLingoError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case permissionDenied(String)
    case noAudioSource
    case captureFailed(String)
    case whisperModelUnavailable(String)
    case whisperIntegrationPending(String)
    case translationFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add an OpenAI Platform API key in Settings before starting translation."
        case .permissionDenied(let message):
            message
        case .noAudioSource:
            "No capturable display or audio source is available."
        case .captureFailed(let message):
            message
        case .whisperModelUnavailable(let message):
            message
        case .whisperIntegrationPending(let message):
            message
        case .translationFailed(let message):
            message
        case .invalidResponse:
            "The translation service returned an unexpected response."
        }
    }
}
