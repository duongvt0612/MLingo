import MLingoCore
import SwiftUI

enum CredentialStatus: Equatable {
    case checking
    case notSaved
    case saved
    case unsavedChange
    case failed(String)

    var message: String {
        switch self {
        case .checking:
            "Checking Keychain…"
        case .notSaved:
            "No API key saved"
        case .saved:
            "Saved in Keychain"
        case .unsavedChange:
            "Unsaved API key change"
        case .failed(let message):
            message
        }
    }
}

extension AppTheme {
    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

extension ProviderKind {
    static let remoteSettingsKinds: [ProviderKind] = [
        .openAI,
        .ollama,
        .lmStudio,
        .custom,
    ]

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .custom: "Custom"
        case .builtInMLX: "Built-in MLX"
        case .system: "System"
        }
    }

    var systemImage: String {
        switch self {
        case .openAI: "cloud"
        case .ollama, .lmStudio: "desktopcomputer"
        case .custom: "server.rack"
        case .builtInMLX: "cpu"
        case .system: "macbook"
        }
    }
}

extension ModelCapability {
    static let providerSettingsCapabilities: [ModelCapability] = [
        .translation,
        .chat,
        .embedding,
        .textToSpeech,
    ]

    var displayName: String {
        switch self {
        case .speechRecognition: "Speech Recognition"
        case .translation: "Translation"
        case .chat: "Chat"
        case .embedding: "Embedding"
        case .textToSpeech: "Text to Speech"
        }
    }

    var systemImage: String {
        switch self {
        case .speechRecognition: "waveform"
        case .translation: "character.book.closed"
        case .chat: "bubble.left.and.bubble.right"
        case .embedding: "square.stack.3d.up"
        case .textToSpeech: "speaker.wave.2"
        }
    }
}

extension ProviderProfileValidationIssue {
    var settingsMessage: String {
        switch self {
        case .emptyName:
            "Enter a profile name."
        case .missingEndpoint:
            "Enter the provider endpoint."
        case .missingEndpointHost:
            "Enter an endpoint with a valid host."
        case .unsupportedEndpointScheme:
            "Use an http or https endpoint."
        case .remoteEndpointRequiresHTTPS:
            "Remote endpoints require HTTPS. HTTP is allowed only for localhost."
        case .endpointContainsCredentials:
            "Remove usernames or passwords from the endpoint and store the secret in Keychain."
        case .endpointContainsQueryOrFragment:
            "Remove query strings and fragments from the endpoint."
        case .invalidCustomHeaderName:
            "Enter a valid HTTP header name."
        case .emptyCredentialID:
            "The credential reference is invalid. Create a new profile."
        }
    }
}

extension ProviderResolutionIssue {
    var settingsMessage: String {
        switch self {
        case .selectionMissing(let capability):
            "Choose a provider for \(capability.displayName)."
        case .profileNotFound:
            "The selected provider no longer exists. Choose another provider or Not configured."
        case .invalidProfile:
            "Fix the selected provider profile before saving."
        case .capabilityUnsupported:
            "The selected provider has no models for this capability."
        case .modelUnavailable(_, _, let model):
            "The selected model \(model) is unavailable. Choose another model."
        }
    }
}
