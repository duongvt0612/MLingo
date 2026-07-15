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
