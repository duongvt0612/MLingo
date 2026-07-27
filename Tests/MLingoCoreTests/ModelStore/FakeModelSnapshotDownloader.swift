import Foundation
@testable import MLingoCore

/// Scripted stand-in for the Hugging Face downloader.
///
/// Shaped after `ScriptedTransportHTTPClient`: a lock-guarded outcome queue plus a record of
/// what was asked for, so tests can assert the request as well as the result. It writes real
/// files into `root` so verification and installation run against a genuine directory.
///
/// It also models per-file resume the way upstream behaves: a file that completed in an
/// earlier attempt stays in the fake's blob store and is not fetched again.
final class FakeModelSnapshotDownloader: ModelSnapshotDownloading, @unchecked Sendable {
    enum Outcome: @unchecked Sendable {
        /// Writes every requested file, each `bytesPerFile` long.
        case success(bytesPerFile: Int = 32)
        /// Writes only the named files, then reports success. Used to build broken snapshots.
        case partial(files: [String], bytesPerFile: Int = 32)
        /// Writes the named files with explicit contents.
        case contents([String: Data])
        case failure(any Error)
        /// Writes the named files, then throws. Models a mid-transfer failure whose completed
        /// files survive for the next attempt.
        case failAfterWriting(files: [String], error: any Error)
        /// Suspends until the calling task is cancelled.
        case blockUntilCancelled
    }

    private let root: URL
    private let progressTicks: Int
    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var storedRequests: [ModelDownloadRequest] = []
    private var storedTokens: [String?] = []
    private var completedFiles: Set<String> = []
    private var storedFetchedFiles: [[String]] = []
    private var inFlight = 0
    private var storedMaxConcurrency = 0

    init(root: URL, outcomes: [Outcome], progressTicks: Int = 4) {
        self.root = root
        self.outcomes = outcomes
        self.progressTicks = progressTicks
    }

    var requests: [ModelDownloadRequest] { lock.withLock { storedRequests } }
    var tokens: [String?] { lock.withLock { storedTokens } }
    /// Files actually transferred per call. Shrinks on retry as earlier files are reused.
    var fetchedFiles: [[String]] { lock.withLock { storedFetchedFiles } }
    var maxObservedConcurrency: Int { lock.withLock { storedMaxConcurrency } }
    var callCount: Int { lock.withLock { storedRequests.count } }

    func downloadSnapshot(
        _ request: ModelDownloadRequest,
        token: String?,
        onProgress: @Sendable @escaping (ModelDownloadProgress) -> Void
    ) async throws -> URL {
        let outcome = lock.withLock { () -> Outcome in
            storedRequests.append(request)
            storedTokens.append(token)
            inFlight += 1
            storedMaxConcurrency = max(storedMaxConcurrency, inFlight)
            return outcomes.isEmpty ? .success() : outcomes.removeFirst()
        }
        defer { lock.withLock { inFlight -= 1 } }

        let destination = snapshotDirectory(for: request)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        switch outcome {
        case .blockUntilCancelled:
            try await Task.sleep(for: .seconds(60))
            return destination

        case .failure(let error):
            lock.withLock { storedFetchedFiles.append([]) }
            throw error

        case .failAfterWriting(let files, let error):
            try write(files.map { ($0, Data(repeating: 0x41, count: 32)) }, to: destination, request: request)
            throw error

        case .success(let bytesPerFile):
            let payload = request.files.map { ($0, Data(repeating: 0x41, count: bytesPerFile)) }
            try await emitProgress(payload, onProgress: onProgress)
            try write(payload, to: destination, request: request)
            return destination

        case .partial(let files, let bytesPerFile):
            let payload = files.map { ($0, Data(repeating: 0x41, count: bytesPerFile)) }
            try await emitProgress(payload, onProgress: onProgress)
            try write(payload, to: destination, request: request)
            return destination

        case .contents(let contents):
            let payload = contents.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
            try await emitProgress(payload, onProgress: onProgress)
            try write(payload, to: destination, request: request)
            return destination
        }
    }

    private func emitProgress(
        _ payload: [(String, Data)],
        onProgress: @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        let total = Int64(payload.reduce(0) { $0 + $1.1.count })
        for tick in 1...max(progressTicks, 1) {
            try Task.checkCancellation()
            let completed = total * Int64(tick) / Int64(max(progressTicks, 1))
            onProgress(ModelDownloadProgress(completedBytes: completed, totalBytes: total))
        }
    }

    private func write(
        _ payload: [(String, Data)],
        to destination: URL,
        request: ModelDownloadRequest
    ) throws {
        var fetched: [String] = []
        for (name, data) in payload {
            let key = "\(request.repository)@\(request.revision)/\(name)"
            let target = destination.appending(path: name, directoryHint: .notDirectory)
            let alreadyPresent = lock.withLock { completedFiles.contains(key) }
            if !alreadyPresent || !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: target, options: [.atomic])
                fetched.append(name)
                lock.withLock { _ = completedFiles.insert(key) }
            }
        }
        lock.withLock { storedFetchedFiles.append(fetched) }
    }

    /// Mirrors the real cache layout closely enough that callers must not assume a flat path.
    private func snapshotDirectory(for request: ModelDownloadRequest) -> URL {
        let repositoryComponent = request.repository.replacingOccurrences(of: "/", with: "--")
        return root
            .appending(path: "models--\(repositoryComponent)", directoryHint: .isDirectory)
            .appending(path: "snapshots", directoryHint: .isDirectory)
            .appending(path: request.revision, directoryHint: .isDirectory)
    }
}
