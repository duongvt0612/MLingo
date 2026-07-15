import Foundation
import MLingoCore

enum AppRecoveryAction: Equatable, Sendable {
    case openSettings
    case openSystemSettings
    case openOpenAIUsage
    case stopTranslation
    case dismiss

    var label: String {
        switch self {
        case .openSettings:
            "Open Settings"
        case .openSystemSettings:
            "Open System Settings"
        case .openOpenAIUsage:
            "Open API Usage"
        case .stopTranslation:
            "Stop Translation"
        case .dismiss:
            "Dismiss"
        }
    }
}

struct AppIssuePresentation: Equatable, Sendable {
    let message: String
    let actions: [AppRecoveryAction]

    init(
        error: MLingoError,
        isTranslationActive: Bool,
        translationProviderKind: ProviderKind? = nil,
        translationProviderEndpoint: URL? = nil
    ) {
        message = error.localizedDescription

        let primaryAction: AppRecoveryAction = switch error {
        case .permissionDenied,
             .systemAudioPermissionDenied,
             .coreAudioHALFailure,
             .noAudioSource,
             .captureFailed:
            .openSystemSettings
        case .quotaExceeded:
            // Only OpenAI accounts have a meaningful platform usage page.
            if translationProviderKind == .openAI,
               translationProviderEndpoint?.isOfficialOpenAIAPIEndpoint == true {
                .openOpenAIUsage
            } else {
                .openSettings
            }
        case .missingAPIKey,
             .whisperModelUnavailable,
             .whisperModelLoadFailed,
             .whisperInferenceFailed,
             .invalidAPIKey,
             .invalidOpenAIModel,
             .translationInputTooLong,
             .invalidTranslationConfiguration,
             .invalidSettings,
             .credentialStoreFailure,
             .translationRequestRejected:
            .openSettings
        case .rateLimited,
             .networkOffline,
             .requestTimedOut,
             .translationServiceUnavailable,
             .translationFailed,
             .invalidResponse:
            .dismiss
        }

        if isTranslationActive,
           error.pausesTranslationSession,
           primaryAction != .stopTranslation
        {
            actions = [primaryAction, .stopTranslation]
        } else {
            actions = [primaryAction]
        }
    }
}

struct AppCommandAvailability: Equatable, Sendable {
    let canStartTranslation: Bool
    let canStop: Bool
    let canToggleOverlay: Bool

    init(activeMode: MLingoViewModel.ActiveMode) {
        canStartTranslation = activeMode == .idle
        canStop = activeMode != .idle
        canToggleOverlay = activeMode == .translation
    }
}
