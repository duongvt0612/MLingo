import Foundation
import HuggingFace
import Testing
@testable import MLingoCore

private func response(_ statusCode: Int) throws -> HTTPURLResponse {
    try #require(
        HTTPURLResponse(
            url: URL(string: "https://huggingface.co/api/models/owner/model")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )
    )
}

private func mappedIssue(_ error: any Error, token: String? = nil) -> ModelStoreIssue? {
    let mapped = HubModelSnapshotDownloader.mapError(error, repository: "owner/model", token: token)
    return (mapped as? ModelStoreError)?.issue
}

@Test
func hubDownloaderMapsHTTPStatusOntoActionableIssues() throws {
    #expect(
        mappedIssue(HTTPClientError.responseError(response: try response(401), detail: "no token"))
            == .authenticationRequired
    )
    #expect(
        mappedIssue(HTTPClientError.responseError(response: try response(403), detail: "gated"))
            == .accessGated(repository: "owner/model")
    )
    #expect(
        mappedIssue(HTTPClientError.responseError(response: try response(404), detail: "gone"))
            == .repositoryNotFound(repository: "owner/model")
    )
    #expect(
        mappedIssue(HTTPClientError.responseError(response: try response(500), detail: "boom"))
            == .transportFailure
    )
    #expect(
        mappedIssue(HTTPClientError.responseError(response: try response(429), detail: "slow down"))
            == .transportFailure
    )
}

@Test
func hubDownloaderMapsOfflineAndDecodingFailuresToARetry() throws {
    #expect(mappedIssue(URLError(.notConnectedToInternet)) == .transportFailure)
    #expect(mappedIssue(URLError(.timedOut)) == .transportFailure)
    #expect(
        mappedIssue(HTTPClientError.decodingError(response: try response(200), detail: "bad json"))
            == .transportFailure
    )
    #expect(mappedIssue(HTTPClientError.unexpectedError("?")) == .transportFailure)
}

@Test
func hubDownloaderPreservesCancellation() {
    let mapped = HubModelSnapshotDownloader.mapError(
        CancellationError(),
        repository: "owner/model",
        token: nil
    )
    #expect(mapped is CancellationError)
}

@Test
func hubDownloaderPassesThroughAnAlreadyTypedError() {
    #expect(mappedIssue(ModelStoreError(issue: .installFailed)) == .installFailed)
}

@Test
func hubDownloaderNeverSurfacesTheTokenInAMappedError() throws {
    let error = HTTPClientError.responseError(
        response: try response(401),
        detail: "Authorization: Bearer hf_supersecret was rejected"
    )
    let mapped = HubModelSnapshotDownloader.mapError(error, repository: "owner/model", token: "hf_supersecret")
    let description = (mapped as? ModelStoreError)?.errorDescription ?? ""
    #expect(!description.contains("hf_supersecret"))
    #expect(!description.contains("Bearer"))
}

@Test
func hubDownloaderRejectsAMalformedRepositoryWithoutMakingARequest() async throws {
    let temporary = try TemporaryDirectory(label: "HubDownloader")
    defer { temporary.remove() }
    let spy = ModelStoreNetworkSpy()
    spy.start()
    defer { spy.stop() }

    let downloader = HubModelSnapshotDownloader(cacheDirectory: temporary.url)
    let request = ModelDownloadRequest(
        repository: "no-slash",
        revision: String(repeating: "a", count: 40),
        files: ["config.json"]
    )

    await #expect(throws: ModelStoreError(issue: .repositoryNotFound(repository: "no-slash"))) {
        _ = try await downloader.downloadSnapshot(request, token: nil) { _ in }
    }
    #expect(spy.requestCount == 0)
}
