import Foundation

public enum CredentialStoreOperation: String, Equatable, Sendable {
    case load
    case inspect
    case add
    case update
    case delete
    case rollback
}

public enum MLingoError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case permissionDenied(String)
    case systemAudioPermissionDenied
    case coreAudioHALFailure(operation: String, status: Int32)
    case noAudioSource
    case captureFailed(String)
    case whisperModelUnavailable(String)
    case whisperModelLoadFailed(String)
    case whisperInferenceFailed(String)
    case invalidAPIKey
    case invalidOpenAIModel
    case quotaExceeded
    case rateLimited
    case networkOffline
    case requestTimedOut
    case translationServiceUnavailable
    case translationInputTooLong(maxCharacters: Int)
    case invalidTranslationConfiguration(String)
    case invalidSettings(String)
    case credentialStoreFailure(operation: CredentialStoreOperation, status: Int32)
    case translationRequestRejected(String)
    case translationFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add an OpenAI Platform API key in Settings before starting translation."
        case .permissionDenied(let message):
            message
        case .systemAudioPermissionDenied:
            "Allow System Audio Recording for MLingo in System Settings > Privacy & Security > Screen & System Audio Recording, then try again."
        case .coreAudioHALFailure(let operation, let status):
            "Core Audio failed during \(operation) (OSStatus \(status))."
        case .noAudioSource:
            "No capturable display or audio source is available."
        case .captureFailed(let message):
            message
        case .whisperModelUnavailable(let message):
            message
        case .whisperModelLoadFailed(let message):
            message
        case .whisperInferenceFailed(let message):
            message
        case .invalidAPIKey:
            "The OpenAI API key is invalid. Update it in Settings and start a new translation session."
        case .invalidOpenAIModel:
            "The selected OpenAI model is unavailable. Check the model name in Settings."
        case .quotaExceeded:
            "The OpenAI account has no available quota. Check billing and usage before trying again."
        case .rateLimited:
            "OpenAI is temporarily rate limiting requests. Try again shortly."
        case .networkOffline:
            "MLingo is offline. Check the network connection before restarting translation."
        case .requestTimedOut:
            "The OpenAI translation request timed out."
        case .translationServiceUnavailable:
            "OpenAI translation is temporarily unavailable."
        case .translationInputTooLong(let maxCharacters):
            "The transcript is too long to translate safely (maximum \(maxCharacters) characters)."
        case .invalidTranslationConfiguration(let message):
            message
        case .invalidSettings(let message):
            message
        case .credentialStoreFailure:
            "MLingo couldn't access the OpenAI API key in Keychain. Check app permissions and try again."
        case .translationRequestRejected(let message):
            message
        case .translationFailed(let message):
            message
        case .invalidResponse:
            "The translation service returned an unexpected response."
        }
    }

    public var pausesTranslationSession: Bool {
        switch self {
        case .missingAPIKey,
             .invalidAPIKey,
             .invalidOpenAIModel,
             .quotaExceeded,
             .networkOffline,
             .translationInputTooLong,
             .invalidTranslationConfiguration,
             .invalidSettings,
             .translationRequestRejected:
            true
        default:
            false
        }
    }
}
