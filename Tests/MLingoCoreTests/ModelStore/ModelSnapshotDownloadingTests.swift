import Foundation
import Testing
@testable import MLingoCore

private func makeRequest(files: [String] = ["config.json", "model.safetensors"]) -> ModelDownloadRequest {
    ModelDownloadRequest(
        repository: "mlx-community/Qwen3-0.6B-4bit",
        revision: String(repeating: "7", count: 40),
        files: files
    )
}

@Test
func fakeDownloaderRecordsTheRequestAndWritesScriptedFiles() async throws {
    let temporary = try TemporaryDirectory(label: "Download")
    defer { temporary.remove() }
    let downloader = FakeModelSnapshotDownloader(root: temporary.url, outcomes: [.success(bytesPerFile: 16)])
    let request = makeRequest()

    let snapshot = try await downloader.downloadSnapshot(request, token: "hf_secret") { _ in }

    #expect(downloader.requests == [request])
    #expect(downloader.tokens == ["hf_secret"])
    for name in request.files {
        let file = snapshot.appending(path: name, directoryHint: .notDirectory)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
    // Weights get the requested size; JSON files get content that actually parses, because a
    // completed file is never refetched and junk would poison every later attempt.
    let weights = try Data(contentsOf: snapshot.appending(path: "model.safetensors"))
    #expect(weights.count == 16)
    let config = try Data(contentsOf: snapshot.appending(path: "config.json"))
    #expect((try? JSONSerialization.jsonObject(with: config)) != nil)
}

@Test
func fakeDownloaderEmitsMonotonicProgressEndingAtTheTotal() async throws {
    let temporary = try TemporaryDirectory(label: "Download")
    defer { temporary.remove() }
    let downloader = FakeModelSnapshotDownloader(
        root: temporary.url,
        outcomes: [.success(bytesPerFile: 25)],
        progressTicks: 5
    )

    let recorded = ProgressRecorder()
    let snapshot = try await downloader.downloadSnapshot(makeRequest(), token: nil) { progress in
        recorded.append(progress)
    }

    let updates = recorded.values
    #expect(updates.count == 5)
    #expect(zip(updates, updates.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes })
    let last = try #require(updates.last)
    #expect(last.completedBytes == last.totalBytes)
    #expect(abs(last.fraction - 1) < 0.000_001)

    let onDisk = try makeRequest().files.reduce(Int64(0)) { total, name in
        let attributes = try FileManager.default.attributesOfItem(
            atPath: snapshot.appending(path: name).path
        )
        return total + ((attributes[.size] as? NSNumber)?.int64Value ?? 0)
    }
    #expect(last.totalBytes == onDisk, "the advertised total must match what was written")
}

@Test
func modelDownloadProgressReportsZeroFractionForAnUnknownTotal() {
    #expect(ModelDownloadProgress(completedBytes: 0, totalBytes: 0).fraction == 0)
    #expect(ModelDownloadProgress(completedBytes: 5, totalBytes: 0).fraction == 0)
    #expect(ModelDownloadProgress(completedBytes: 5, totalBytes: 10).fraction == 0.5)
    // Upstream can report more than it first advertised; the fraction must stay in range.
    #expect(ModelDownloadProgress(completedBytes: 20, totalBytes: 10).fraction == 1)
}

@Test
func fakeDownloaderPropagatesCancellation() async throws {
    let temporary = try TemporaryDirectory(label: "Download")
    defer { temporary.remove() }
    let downloader = FakeModelSnapshotDownloader(root: temporary.url, outcomes: [.blockUntilCancelled])

    let task = Task {
        try await downloader.downloadSnapshot(makeRequest(), token: nil) { _ in }
    }
    try await eventually { downloader.callCount == 1 }
    task.cancel()

    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
}

@Test
func fakeDownloaderSkipsFilesCompletedByAnEarlierAttempt() async throws {
    let temporary = try TemporaryDirectory(label: "Download")
    defer { temporary.remove() }
    // Mirrors upstream: a completed file stays in the blob store, so a retry only fetches the rest.
    let downloader = FakeModelSnapshotDownloader(
        root: temporary.url,
        outcomes: [
            .failAfterWriting(files: ["config.json"], error: URLError(.networkConnectionLost)),
            .success()
        ]
    )
    let request = makeRequest()

    await #expect(throws: URLError.self) {
        _ = try await downloader.downloadSnapshot(request, token: nil) { _ in }
    }
    _ = try await downloader.downloadSnapshot(request, token: nil) { _ in }

    #expect(downloader.fetchedFiles == [["config.json"], ["model.safetensors"]])
}

@Test
func modelDownloadRequestKeepsTheCatalogFileList() {
    let entry = MLingoModelCatalog.qwen3Chat
    let request = ModelDownloadRequest(entry: entry)
    #expect(request.repository == entry.repository)
    #expect(request.revision == entry.revision)
    #expect(request.files == entry.files)
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [ModelDownloadProgress] = []

    var values: [ModelDownloadProgress] { lock.withLock { storedValues } }

    func append(_ progress: ModelDownloadProgress) {
        lock.withLock { storedValues.append(progress) }
    }
}
