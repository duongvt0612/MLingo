import Foundation
import HuggingFace

/// The Hugging Face download path, and the only file in this module that imports `HuggingFace`.
///
/// Two upstream behaviours shape it:
///
/// The `to:` parameter of `downloadSnapshot` is not used. It stores each file in the cache and
/// then copies it to the destination, so a model costs twice its size during install; passing
/// `cache: nil` to avoid that throws only after the whole download has finished. Fetching into
/// MLingo's own cache and hardlinking out of it costs one copy.
///
/// The client is always built with an explicit bearer token. The default token provider searches
/// six locations including `~/.cache/huggingface/token`, which would silently authenticate with
/// whatever the developer happens to have logged in with and make results machine-dependent.
public final class HubModelSnapshotDownloader: ModelSnapshotDownloading {
    private let cacheDirectory: URL
    private let host: URL
    private let maximumConcurrentDownloads: Int

    public init(
        cacheDirectory: URL,
        host: URL = HubClient.defaultHost,
        maximumConcurrentDownloads: Int = 4
    ) {
        self.cacheDirectory = cacheDirectory
        self.host = host
        self.maximumConcurrentDownloads = maximumConcurrentDownloads
    }

    public func downloadSnapshot(
        _ request: ModelDownloadRequest,
        token: String?,
        onProgress: @Sendable @escaping (ModelDownloadProgress) -> Void
    ) async throws -> URL {
        guard let repository = Repo.ID(rawValue: request.repository) else {
            // `Repo.ID` splits on the first slash without validating either half, so a malformed
            // identifier is rejected here rather than turned into a request.
            throw ModelStoreError(issue: .repositoryNotFound(repository: request.repository))
        }

        let client = HubClient(
            host: host,
            userAgent: "MLingo",
            bearerToken: token,
            cache: HubCache(cacheDirectory: cacheDirectory)
        )

        do {
            return try await client.downloadSnapshot(
                of: repository,
                revision: request.revision,
                matching: request.files,
                maxConcurrentDownloads: maximumConcurrentDownloads,
                progressHandler: { progress in
                    onProgress(
                        ModelDownloadProgress(
                            completedBytes: progress.completedUnitCount,
                            totalBytes: progress.totalUnitCount
                        )
                    )
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapError(error, repository: request.repository, token: token)
        }
    }

    /// Upstream reports every HTTP failure as one case, so the status code is what distinguishes
    /// a missing token from a licence that has not been accepted.
    static func mapError(_ error: any Error, repository: String, token: String?) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let storeError = error as? ModelStoreError { return storeError }

        if let clientError = error as? HTTPClientError {
            switch clientError {
            case .responseError(let response, let detail):
                logResponse(response, detail: detail, token: token)
                return ModelStoreError(issue: issue(for: response.statusCode, repository: repository))
            case .decodingError, .requestError, .unexpectedError:
                return ModelStoreError(issue: .transportFailure)
            }
        }

        return ModelStoreError(issue: .transportFailure)
    }

    private static func issue(for statusCode: Int, repository: String) -> ModelStoreIssue {
        switch statusCode {
        case 401: .authenticationRequired
        case 403: .accessGated(repository: repository)
        case 404, 410: .repositoryNotFound(repository: repository)
        default: .transportFailure
        }
    }

    /// The status is ours to report; the server's message is not. It can echo a request header,
    /// so it goes through the redactor and stays private even then.
    private static func logResponse(_ response: HTTPURLResponse, detail: String, token: String?) {
        let safeDetail = ProviderDiagnosticRedactor.safeDescription(
            detail,
            secrets: [token].compactMap { $0 }
        )
        MLingoLogger.models.error(
            """
            Model download failed HTTP \(response.statusCode, privacy: .public), \
            detail \(safeDetail, privacy: .private)
            """
        )
    }
}
