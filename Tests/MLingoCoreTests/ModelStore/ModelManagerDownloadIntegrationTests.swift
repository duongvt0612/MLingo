import Foundation
import Testing
@testable import MLingoCore

/// Opt-in suite that downloads real bytes from Hugging Face. Requires:
/// - `MLINGO_RUN_MODEL_DOWNLOAD_TESTS=1`
///
/// Gate off, these return immediately, matching how the live provider and local MLX suites
/// already work. Gate on but misconfigured, they throw rather than skipping quietly.
private var shouldRunDownloadTests: Bool {
    ProcessInfo.processInfo.environment["MLINGO_RUN_MODEL_DOWNLOAD_TESTS"] == "1"
}

@Test
func modelManagerDownloadsVerifiesInstallsAndDeletesWhisperWhenEnabled() async throws {
    guard shouldRunDownloadTests else { return }

    let temporary = try TemporaryDirectory(label: "DownloadIntegration")
    defer { temporary.remove() }
    let layout = ModelStorageLayout(root: temporary.appending("Models", isDirectory: true))
    try layout.createBuckets()
    let entry = MLingoModelCatalog.whisperBase

    func makeManager() -> ModelManager {
        ModelManager(
            layout: layout,
            downloader: HubModelSnapshotDownloader(cacheDirectory: layout.hubCacheRoot),
            catalog: [entry]
        )
    }

    let manager = makeManager()
    await manager.install(entry.id)

    let state = await manager.state(for: entry.id)
    #expect(state == .installed, "install ended in \(state)")
    let installed = try #require(await manager.installedDirectory(for: entry.id))

    // Everything the loader needs has to be present, or the model is only offline by luck:
    // WhisperModel.fromDirectory downloads a tokenizer from another repository when one is absent.
    let contents = try FileManager.default.contentsOfDirectory(atPath: installed.path)
    #expect(contents.contains("tokenizer.json"))
    #expect(contents.contains("config.json"))
    #expect(contents.contains { $0.hasSuffix(".safetensors") })

    // The cache copy is dropped once the bytes are hardlinked into place.
    let cached = try FileManager.default.contentsOfDirectory(atPath: layout.hubCacheRoot.path)
    #expect(!cached.contains { $0.hasPrefix("models--") }, "cache still holds \(cached)")

    let usage = try ModelStorageAccounting(layout: layout).usage()
    #expect(usage.installedBytes > 100_000_000)
    #expect(usage.totalBytes < entry.expectedBytes * 2, "the model should be stored once, not twice")

    // Restart reuse: a fresh manager over the same store must not download again.
    let reopened = makeManager()
    #expect(await reopened.state(for: entry.id) == .installed)
    #expect(await reopened.installedDirectory(for: entry.id) != nil)

    try await reopened.delete(entry.id)
    #expect(await reopened.state(for: entry.id) == .notInstalled)
    #expect(try FileManager.default.contentsOfDirectory(atPath: layout.installedRoot.path).isEmpty)
}

@Test
func downloadingAnUnknownRevisionReportsRepositoryNotFoundWhenEnabled() async throws {
    guard shouldRunDownloadTests else { return }

    let temporary = try TemporaryDirectory(label: "DownloadIntegration")
    defer { temporary.remove() }
    let downloader = HubModelSnapshotDownloader(cacheDirectory: temporary.url)
    let request = ModelDownloadRequest(
        repository: "mlx-community/whisper-base-asr-fp16",
        revision: String(repeating: "0", count: 40),
        files: ["config.json"]
    )

    // Exercises the real status-code mapping rather than a hand-built HTTPURLResponse.
    await #expect(throws: ModelStoreError.self) {
        _ = try await downloader.downloadSnapshot(request, token: nil) { _ in }
    }
}
