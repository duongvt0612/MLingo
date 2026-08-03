import Foundation
import MLingoCore

/// How one catalog row reads.
///
/// Text and symbol carry the state; colour only reinforces it. `ModelLifecycleState` has twelve
/// cases and several of them mean "wait", so the titles are kept distinct — "Verifying" and
/// "Installing" look alike as spinners but mean different things when one of them fails.
struct ModelRowPresentation: Equatable {
    let title: String
    let systemImage: String
    let detail: String?
    /// Present only for a download with a known total, so the bar is never a lie.
    let progressFraction: Double?
    let isError: Bool

    init(state: ModelLifecycleState) {
        switch state {
        case .notInstalled:
            title = "Not installed"
            systemImage = "circle.dashed"
            detail = nil
            progressFraction = nil
            isError = false

        case .probing:
            title = "Checking"
            systemImage = "magnifyingglass"
            detail = "Checking available space"
            progressFraction = nil
            isError = false

        case .queued(let position):
            title = "Queued"
            systemImage = "clock"
            detail = "Waiting for another download, position \(position)"
            progressFraction = nil
            isError = false

        case .downloading(let completed, let total):
            title = "Downloading"
            systemImage = "arrow.down.circle"
            detail = total > 0
                ? "\(Self.formatted(completed)) of \(Self.formatted(total))"
                : Self.formatted(completed)
            progressFraction = total > 0
                ? min(max(Double(completed) / Double(total), 0), 1)
                : nil
            isError = false

        case .verifying:
            title = "Verifying"
            systemImage = "checkmark.shield"
            detail = "Checking the downloaded files"
            progressFraction = nil
            isError = false

        case .installing:
            title = "Installing"
            systemImage = "shippingbox"
            detail = "Moving the model into place"
            progressFraction = nil
            isError = false

        case .installed:
            title = "Installed"
            systemImage = "checkmark.circle"
            detail = nil
            progressFraction = nil
            isError = false

        case .loading:
            title = "Loading"
            systemImage = "hourglass"
            detail = "The runtime is loading this model"
            progressFraction = nil
            isError = false

        case .ready(let leaseCount):
            title = "In use"
            systemImage = "bolt.circle"
            detail = "Held by \(leaseCount) active use(s)"
            progressFraction = nil
            isError = false

        case .failed(let error):
            title = "Failed"
            systemImage = "exclamationmark.triangle"
            detail = error.errorDescription
            progressFraction = nil
            isError = true

        case .cancelled:
            title = "Cancelled"
            systemImage = "xmark.circle"
            detail = "The download was stopped before it finished"
            progressFraction = nil
            isError = false

        case .quarantined(let reason):
            title = "Quarantined"
            systemImage = "exclamationmark.octagon"
            detail = ModelStoreError(issue: reason.issue).errorDescription
            progressFraction = nil
            isError = true
        }
    }

    /// One sentence for VoiceOver, because a row read as "Downloading" alone says nothing about
    /// how far along it is.
    var accessibilityLabel: String {
        var parts = [title]
        if let progressFraction {
            parts.append("\(Int((progressFraction * 100).rounded()))%")
        }
        if let detail {
            parts.append(detail)
        }
        return parts.joined(separator: ", ")
    }

    private static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}

/// Why a control is unavailable, phrased for the user rather than as a boolean.
///
/// A disabled button with no explanation is a dead end, so each answer is the text the pane puts
/// next to it.
enum ModelActionAvailability {
    static func downloadDisabledReason(
        state: ModelLifecycleState,
        hasPendingTokenChange: Bool
    ) -> String? {
        if state.isBusy {
            return "This model is already being downloaded."
        }
        if hasPendingTokenChange {
            return "Save Settings before downloading so the new Hugging Face token is used."
        }
        return nil
    }

    static func deleteDisabledReason(
        state: ModelLifecycleState,
        isSessionRunning: Bool
    ) -> String? {
        switch state {
        case .notInstalled, .cancelled:
            return "This model is not on disk."
        case .probing, .queued, .downloading, .verifying, .installing, .loading:
            return "Cancel the download before deleting this model."
        case .ready:
            return "This model is in use. Stop what is using it before deleting."
        case .installed, .failed, .quarantined:
            break
        }
        // The runtime keeps Whisper weights loaded for the whole of a session, and the store
        // refuses to delete underneath it; saying so up front beats a failed delete.
        return isSessionRunning ? "Stop live translation before deleting a model." : nil
    }

    static func isCancellable(_ state: ModelLifecycleState) -> Bool {
        state.isBusy
    }
}

extension ModelRole {
    var displayName: String {
        switch self {
        case .speechRecognition: "Speech recognition"
        case .chat: "Chat and translation"
        case .embedding: "Embedding"
        }
    }
}

extension ModelCatalogEntry {
    /// The storage slug reads better in a list than the full `owner/name` identifier, which is
    /// already shown as the repository.
    var displayName: String { slug.rawValue }

    /// The pinned commit, abbreviated. Reproducibility is the point of pinning it, so it is shown
    /// — but forty hex characters in a list column help nobody.
    var shortRevision: String { String(revision.prefix(7)) }
}

/// What a recovery button does. Every `ModelStoreRecoveryAction` maps onto one of these.
enum ModelRecoveryCommand: Equatable {
    case retry(ModelID)
    case focusToken
    case openPage(URL)
    case stopSession
    case revealStorage
    case copyDiagnostics(String)

    init(action: ModelStoreRecoveryAction, model: ModelID, message: String) {
        switch action {
        case .retryDownload, .reinstallModel:
            self = .retry(model)
        case .addHuggingFaceToken:
            self = .focusToken
        case .acceptRepositoryLicence(let repository):
            // A repository name also arrives from a persisted quarantine reason, so a value that
            // cannot become a URL must still leave the user with something to do.
            if let url = Self.repositoryPage(repository) {
                self = .openPage(url)
            } else {
                self = .copyDiagnostics("\(model.rawValue): \(message)")
            }
        case .stopActiveSession:
            self = .stopSession
        case .freeDiskSpace, .checkStorageAccess:
            self = .revealStorage
        case .reportBug:
            self = .copyDiagnostics("\(model.rawValue): \(message)")
        }
    }

    private static func repositoryPage(_ repository: String) -> URL? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
        }) else {
            return nil
        }
        return URL(string: "https://huggingface.co/\(repository)")
    }
}
