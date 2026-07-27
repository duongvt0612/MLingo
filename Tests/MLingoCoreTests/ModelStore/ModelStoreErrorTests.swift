import Foundation
import Testing
@testable import MLingoCore

/// Representative issue per case. `recoveryAction` switches exhaustively, so the compiler
/// already guarantees every case maps to something; this list checks the mapping is useful.
private let sampleIssues: [ModelStoreIssue] = [
    .unknownModel(ModelID("mlx-community/nope")),
    .storageUnavailable,
    .insufficientDiskSpace(requiredBytes: 900, availableBytes: 100),
    .authenticationRequired,
    .accessGated(repository: "meta-llama/Llama-3"),
    .repositoryNotFound(repository: "mlx-community/gone"),
    .transportFailure,
    .missingRequiredFile("tokenizer.json"),
    .emptyFile("model.safetensors"),
    .malformedManifest("config.json"),
    .unsafeSnapshotEntry("evil"),
    .snapshotTooLarge(actualBytes: 4_000, allowedBytes: 1_000),
    .digestMismatch("model.safetensors"),
    .installFailed,
    .modelInUse(ModelID("mlx-community/whisper-base-mlx"))
]

@Test
func modelStoreErrorMapsEveryIssueToARecoveryAction() {
    for issue in sampleIssues {
        let error = ModelStoreError(issue: issue)
        #expect(!error.recoveryAction.title.isEmpty, "\(issue) has an unlabelled recovery action")
        #expect(error.errorDescription?.isEmpty == false, "\(issue) has no description")
    }
}

@Test
func modelStoreErrorRoutesAuthenticationAndLicenceIssuesToDistinctRecoveries() {
    #expect(ModelStoreError(issue: .authenticationRequired).recoveryAction == .addHuggingFaceToken)
    #expect(
        ModelStoreError(issue: .accessGated(repository: "meta-llama/Llama-3")).recoveryAction
            == .acceptRepositoryLicence(repository: "meta-llama/Llama-3")
    )
    #expect(ModelStoreError(issue: .transportFailure).recoveryAction == .retryDownload)
    #expect(
        ModelStoreError(issue: .modelInUse(ModelID("a/b"))).recoveryAction == .stopActiveSession
    )
    #expect(
        ModelStoreError(issue: .insufficientDiskSpace(requiredBytes: 2, availableBytes: 1))
            .recoveryAction == .freeDiskSpace
    )
}

@Test
func modelStoreErrorDescriptionNeverContainsAFilesystemPath() {
    // Descriptions surface in Settings. Absolute paths leak the account name, so issues
    // carry a bare file name at most. Repository identifiers keep their slash on purpose.
    for issue in sampleIssues {
        let description = ModelStoreError(issue: issue).errorDescription ?? ""
        #expect(!description.contains(NSHomeDirectory()), "\(issue) leaked the home directory")
        for marker in ["/Users/", "/private/", "/var/", "Library/Application Support"] {
            #expect(!description.contains(marker), "\(issue) leaked \(marker)")
        }
    }
}

@Test
func modelStoreIssuesCarryFileNamesRatherThanPaths() {
    // Guards the rule above at the source: if a path ever reaches an issue, this fails
    // regardless of how the description is worded.
    let pathBearing: [ModelStoreIssue] = [
        .missingRequiredFile("a/b/tokenizer.json"),
        .emptyFile("/tmp/model.safetensors"),
        .malformedManifest("nested/config.json"),
        .unsafeSnapshotEntry("../escape"),
        .digestMismatch("/Users/someone/model.safetensors")
    ]
    for issue in pathBearing {
        let description = ModelStoreError(issue: issue).errorDescription ?? ""
        #expect(!description.contains("/"), "\(issue) must be reduced to a file name")
    }
}

@Test
func modelStorePersistencePolicyDeclaresTheFileSystemBackend() {
    #expect(MLingoPersistencePolicy.modelAssets.backend == .fileSystem)
    #expect(MLingoPersistencePolicy.all.contains(MLingoPersistencePolicy.modelAssets))
    #expect(!MLingoPersistencePolicy.modelAssets.note.isEmpty)
}
