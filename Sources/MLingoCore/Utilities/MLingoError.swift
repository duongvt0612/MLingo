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
    case localModelUnavailable(String)
    case localModelLoadFailed(String)
    case insufficientLocalModelMemory(requiredBytes: UInt64, availableBytes: UInt64)
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
            "Add a provider API key in Settings before starting translation."
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
        case .localModelUnavailable(let message):
            message
        case .localModelLoadFailed(let message):
            message
        case .insufficientLocalModelMemory(let requiredBytes, let availableBytes):
            "The selected local model needs \(Self.formatBytes(requiredBytes)) of unified memory, but only \(Self.formatBytes(availableBytes)) is available. Choose a smaller local model or close other apps."
        case .invalidAPIKey:
            "The provider API key is invalid. Update it in Settings and start a new translation session."
        case .invalidOpenAIModel:
            "The selected translation model is unavailable. Check the model name in Settings."
        case .quotaExceeded:
            "The provider account has no available quota. Check billing and usage before trying again."
        case .rateLimited:
            "The translation provider is temporarily rate limiting requests. Try again shortly."
        case .networkOffline:
            "MLingo is offline. Check the network connection before restarting translation."
        case .requestTimedOut:
            "The translation request timed out."
        case .translationServiceUnavailable:
            "Translation is temporarily unavailable."
        case .translationInputTooLong(let maxCharacters):
            "The transcript is too long to translate safely (maximum \(maxCharacters) characters)."
        case .invalidTranslationConfiguration(let message):
            message
        case .invalidSettings(let message):
            message
        case .credentialStoreFailure:
            "MLingo couldn't access the provider credential in Keychain. Check app permissions and try again."
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
             .localModelUnavailable,
             .localModelLoadFailed,
             .insufficientLocalModelMemory,
             .translationRequestRejected:
            true
        default:
            false
        }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}
