import Foundation
import MLingoCore
import Testing
@testable import MLingoApp

private let presentationModelID = ModelID("mlx-community/whisper-base-mlx")

private let everyLifecycleState: [ModelLifecycleState] = [
    .notInstalled,
    .probing,
    .queued(position: 2),
    .downloading(completedBytes: 45_000_000, totalBytes: 148_065_824),
    .verifying,
    .installing,
    .installed,
    .loading,
    .ready(leaseCount: 1),
    .failed(ModelStoreError(issue: .transportFailure)),
    .cancelled,
    .quarantined(reason: .digestMismatch),
]

@Test
func everyModelStateIsConveyedByTextAndSymbol() {
    for state in everyLifecycleState {
        let row = ModelRowPresentation(state: state)
        #expect(!row.title.isEmpty, "\(state) has no title")
        #expect(!row.systemImage.isEmpty, "\(state) has no symbol")
        #expect(!row.accessibilityLabel.isEmpty, "\(state) has no accessibility label")
    }
    // Distinct states must read differently; colour is never the only difference.
    let titles = everyLifecycleState.map { ModelRowPresentation(state: $0).title }
    #expect(Set(titles).count == titles.count)
}

@Test
func downloadingReportsADeterminateFractionAndByteDetail() {
    let row = ModelRowPresentation(
        state: .downloading(completedBytes: 74_000_000, totalBytes: 148_000_000)
    )

    #expect(row.progressFraction == 0.5)
    let detail = row.detail ?? ""
    #expect(detail.contains("of"))
    #expect(row.accessibilityLabel.contains("50%"))
}

@Test
func aDownloadWithoutATotalStaysIndeterminateRatherThanShowingAFalseFraction() {
    #expect(ModelRowPresentation(state: .downloading(completedBytes: 10, totalBytes: 0))
        .progressFraction == nil)
    #expect(ModelRowPresentation(state: .verifying).progressFraction == nil)
    #expect(ModelRowPresentation(state: .installed).progressFraction == nil)
}

@Test
func failedAndQuarantinedStatesCarryTheirMessage() {
    let failed = ModelRowPresentation(state: .failed(ModelStoreError(issue: .authenticationRequired)))
    #expect(failed.isError)
    #expect(failed.detail == "This model requires a Hugging Face token.")

    let quarantined = ModelRowPresentation(state: .quarantined(reason: .digestMismatch))
    #expect(quarantined.isError)
    #expect(quarantined.detail?.isEmpty == false)

    #expect(ModelRowPresentation(state: .installed).isError == false)
}

@Test
func queuedAndInUseStatesSayWhyTheyAreWaitingOrHeld() {
    #expect(ModelRowPresentation(state: .queued(position: 3)).detail?.contains("3") == true)
    #expect(ModelRowPresentation(state: .ready(leaseCount: 2)).detail?.contains("2") == true)
}

@Test
func downloadIsRefusedWhileWorkIsUnderWayOrTheTokenIsUnsaved() {
    #expect(ModelActionAvailability.downloadDisabledReason(
        state: .notInstalled, hasPendingTokenChange: false
    ) == nil)

    #expect(ModelActionAvailability.downloadDisabledReason(
        state: .downloading(completedBytes: 0, totalBytes: 10), hasPendingTokenChange: false
    ) != nil)

    let tokenReason = ModelActionAvailability.downloadDisabledReason(
        state: .notInstalled, hasPendingTokenChange: true
    )
    #expect(tokenReason?.contains("Save") == true)
}

@Test
func deleteIsRefusedWhileASessionRunsOrTheModelIsBusy() {
    #expect(ModelActionAvailability.deleteDisabledReason(
        state: .installed, isSessionRunning: false
    ) == nil)

    let runningReason = ModelActionAvailability.deleteDisabledReason(
        state: .installed, isSessionRunning: true
    )
    #expect(runningReason?.isEmpty == false)

    #expect(ModelActionAvailability.deleteDisabledReason(
        state: .ready(leaseCount: 1), isSessionRunning: false
    ) != nil)
    #expect(ModelActionAvailability.deleteDisabledReason(
        state: .downloading(completedBytes: 0, totalBytes: 10), isSessionRunning: false
    ) != nil)
    // Nothing on disk, nothing to delete.
    #expect(ModelActionAvailability.deleteDisabledReason(
        state: .notInstalled, isSessionRunning: false
    ) != nil)
    // A quarantined snapshot is still occupying disk, so it must stay removable.
    #expect(ModelActionAvailability.deleteDisabledReason(
        state: .quarantined(reason: .digestMismatch), isSessionRunning: false
    ) == nil)
}

@Test
func cancelIsOfferedOnlyWhileADownloadCanStillBeStopped() {
    #expect(ModelActionAvailability.isCancellable(.downloading(completedBytes: 0, totalBytes: 10)))
    #expect(ModelActionAvailability.isCancellable(.queued(position: 1)))
    #expect(ModelActionAvailability.isCancellable(.probing))
    #expect(ModelActionAvailability.isCancellable(.installed) == false)
    #expect(ModelActionAvailability.isCancellable(.notInstalled) == false)
}

@Test
func everyStoreIssueReachesTheUserWithAMessageAndAWorkingControl() {
    let issues: [ModelStoreIssue] = [
        .unknownModel(presentationModelID),
        .modelNotInstalled(presentationModelID),
        .storageUnavailable,
        .insufficientDiskSpace(requiredBytes: 1_000, availableBytes: 10),
        .authenticationRequired,
        .accessGated(repository: "mlx-community/whisper-base-asr-fp16"),
        .repositoryNotFound(repository: "mlx-community/whisper-base-asr-fp16"),
        .transportFailure,
        .missingRequiredFile("config.json"),
        .emptyFile("model.safetensors"),
        .malformedManifest("config.json"),
        .unsafeSnapshotEntry("../escape"),
        .snapshotTooLarge(actualBytes: 10, allowedBytes: 1),
        .tooManyFiles(actual: 900, allowed: 64),
        .digestMismatch("model.safetensors"),
        .installFailed,
        .modelInUse(presentationModelID),
        .refusedOutsideStore("/etc/passwd"),
    ]

    for issue in issues {
        let error = ModelStoreError(issue: issue)
        let message = error.errorDescription ?? ""
        #expect(!message.isEmpty, "\(issue) has no message")
        #expect(!error.recoveryAction.title.isEmpty)

        let row = ModelRowPresentation(state: .failed(error))
        #expect(row.detail == message)

        let command = ModelRecoveryCommand(
            action: error.recoveryAction,
            model: presentationModelID,
            message: message
        )
        // A control that does nothing is worse than no control. Exhaustive by construction:
        // adding a command the pane cannot run stops this switch from compiling.
        switch command {
        case .retry, .focusToken, .openPage, .stopSession, .revealStorage, .copyDiagnostics:
            break
        }
    }
}

@Test
func licenceRecoveryOpensTheRepositoryPageAndBugReportsCopyTheMessage() {
    let licence = ModelRecoveryCommand(
        action: .acceptRepositoryLicence(repository: "mlx-community/whisper-base-asr-fp16"),
        model: presentationModelID,
        message: "gated"
    )
    #expect(licence == .openPage(
        URL(string: "https://huggingface.co/mlx-community/whisper-base-asr-fp16")!
    ))

    let bug = ModelRecoveryCommand(action: .reportBug, model: presentationModelID, message: "boom")
    #expect(bug == .copyDiagnostics("mlx-community/whisper-base-mlx: boom"))

    #expect(ModelRecoveryCommand(action: .retryDownload, model: presentationModelID, message: "")
        == .retry(presentationModelID))
    #expect(ModelRecoveryCommand(action: .reinstallModel, model: presentationModelID, message: "")
        == .retry(presentationModelID))
    #expect(ModelRecoveryCommand(action: .addHuggingFaceToken, model: presentationModelID, message: "")
        == .focusToken)
    #expect(ModelRecoveryCommand(action: .stopActiveSession, model: presentationModelID, message: "")
        == .stopSession)
    #expect(ModelRecoveryCommand(action: .freeDiskSpace, model: presentationModelID, message: "")
        == .revealStorage)
    #expect(ModelRecoveryCommand(action: .checkStorageAccess, model: presentationModelID, message: "")
        == .revealStorage)
}

@Test
func aRepositoryNameThatCannotBecomeAURLFallsBackToAReportableCommand() {
    // Catalog rows are compile-time data, but the repository also arrives inside a persisted
    // quarantine reason, so an unusable value must not produce a dead button.
    let command = ModelRecoveryCommand(
        action: .acceptRepositoryLicence(repository: "not a repository"),
        model: presentationModelID,
        message: "gated"
    )
    #expect(command == .copyDiagnostics("mlx-community/whisper-base-mlx: gated"))
}

@Test
func everyCatalogRoleAndEntryHasANameTheListCanShow() {
    for role in ModelRole.allCases {
        #expect(!role.displayName.isEmpty, "\(role) has no display name")
    }
    #expect(Set(ModelRole.allCases.map(\.displayName)).count == ModelRole.allCases.count)

    for entry in MLingoModelCatalog.v1 {
        #expect(!entry.displayName.isEmpty)
        // The pinned revision is what makes a download reproducible, so the pane shows it — but
        // a forty-character SHA in a list column helps nobody.
        #expect(entry.shortRevision.count == 7)
        #expect(entry.revision.hasPrefix(entry.shortRevision))
    }
}
