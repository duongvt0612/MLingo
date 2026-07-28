import Foundation
import Testing
@testable import MLingoCore

private let catalogID = "mlx-community/whisper-base-mlx"
private let aliasRepository = "mlx-community/whisper-base-asr-fp16"

private actor StubDirectoryResolver: ModelDirectoryResolving {
    private let installed: [String: URL]
    private(set) var requestedIdentifiers: [String] = []

    init(installed: [String: URL]) {
        self.installed = installed
    }

    func installedDirectory(forModelID id: String) -> URL? {
        requestedIdentifiers.append(id)
        return installed[id]
    }
}

@Test
func whisperResolvesAnInstalledDirectoryWhenTheResolverKnowsTheCatalogIdentifier() async throws {
    let temporary = try TemporaryDirectory(label: "WhisperResolve")
    defer { temporary.remove() }
    let resolver = StubDirectoryResolver(installed: [catalogID: temporary.url])

    let source = await MLXAudioWhisperBackend.resolveSource(for: catalogID, using: resolver)

    #expect(source == .installedDirectory(temporary.url))
}

@Test
func whisperAlsoAcceptsTheAliasTheRepositoryIsKnownBy() async throws {
    let temporary = try TemporaryDirectory(label: "WhisperResolve")
    defer { temporary.remove() }
    // Settings stores the catalog identifier while mlx-audio speaks the alias it maps to, so both
    // have to resolve or an installed model would be re-downloaded.
    let resolver = StubDirectoryResolver(installed: [aliasRepository: temporary.url])

    let source = await MLXAudioWhisperBackend.resolveSource(for: catalogID, using: resolver)

    #expect(source == .installedDirectory(temporary.url))
    #expect(await resolver.requestedIdentifiers == [catalogID, aliasRepository])
}

@Test
func whisperFallsBackToDownloadingWhenNothingIsInstalled() async {
    let resolver = StubDirectoryResolver(installed: [:])

    let source = await MLXAudioWhisperBackend.resolveSource(for: catalogID, using: resolver)

    // This is what keeps an installation that predates the model store working, offline included.
    #expect(source == .pretrained(aliasRepository))
}

@Test
func whisperWithoutAResolverBehavesExactlyAsBefore() async {
    let source = await MLXAudioWhisperBackend.resolveSource(for: catalogID, using: nil)
    #expect(source == .pretrained(aliasRepository))

    let unaliased = await MLXAudioWhisperBackend.resolveSource(for: "openai/whisper-tiny", using: nil)
    #expect(unaliased == .pretrained("openai/whisper-tiny"))
}

@Test
func existingWhisperEngineInitialisersStillCompile() throws {
    let temporary = try TemporaryDirectory(label: "WhisperResolve")
    defer { temporary.remove() }

    // Guards the promise that adding the seam changed no existing call site.
    _ = MLXWhisperEngine()
    _ = MLXAudioWhisperBackend()
    _ = MLXAudioWhisperBackend(cacheDirectory: temporary.url)
    _ = MLXAudioWhisperBackend(cacheDirectory: temporary.url, isMetalLibraryAvailable: { false })
}

@Test
func modelManagerResolvesInstalledDirectoriesByRawIdentifier() async throws {
    let temporary = try TemporaryDirectory(label: "WhisperResolve")
    defer { temporary.remove() }
    let layout = ModelStorageLayout(root: temporary.appending("Models", isDirectory: true))
    let entry = MLingoModelCatalog.whisperBase
    let manager = ModelManager(
        layout: layout,
        downloader: FakeModelSnapshotDownloader(root: layout.hubCacheRoot, outcomes: [.success()]),
        catalog: [entry],
        accounting: ModelStorageAccounting(layout: layout, availableBytes: { 1 << 40 }),
        progressThrottle: .zero
    )

    #expect(await manager.installedDirectory(forModelID: entry.id.rawValue) == nil)
    await manager.install(entry.id)

    let resolved = await manager.installedDirectory(forModelID: entry.id.rawValue)
    #expect(resolved?.lastPathComponent == "whisper-base-mlx")
    #expect(await manager.installedDirectory(forModelID: "owner/unknown") == nil)
}

@Test
func whisperEngineReportsResidencyAndUnloadsOnRequest() async throws {
    let temporary = try TemporaryDirectory(label: "WhisperResolve")
    defer { temporary.remove() }
    let backend = ResidentWhisperBackend(directory: temporary.url)
    let engine = MLXWhisperEngine(backend: backend)
    try await engine.loadModel(named: catalogID)

    #expect(await engine.residentModelDirectories() == [temporary.url])
    // The engine keeps no lease of its own; the session-scoped ModelManager lease is what guards
    // a running transcription, so eviction here only drops the weights.
    #expect(await engine.leaseCount(at: temporary.url) == 0)

    #expect(await engine.requestEviction(at: temporary.url))
    #expect(await backend.unloadCount == 1)
    #expect(await engine.residentModelDirectories().isEmpty)

    // Cleared bookkeeping means the next start reloads rather than assuming it is still there.
    try await engine.loadModel(named: catalogID)
    #expect(await backend.loadCount == 2)
}

@Test
func whisperEngineIgnoresEvictionOfADirectoryItDoesNotHold() async throws {
    let temporary = try TemporaryDirectory(label: "WhisperResolve")
    defer { temporary.remove() }
    let backend = ResidentWhisperBackend(directory: temporary.url)
    let engine = MLXWhisperEngine(backend: backend)
    try await engine.loadModel(named: catalogID)

    #expect(await engine.requestEviction(at: temporary.appending("other", isDirectory: true)))
    #expect(await backend.unloadCount == 0, "an unrelated delete must not unload the live model")
}

private actor ResidentWhisperBackend: WhisperInferenceBackend {
    private var directory: URL?
    private let installedDirectory: URL
    private(set) var unloadCount = 0
    private(set) var loadCount = 0

    init(directory: URL) {
        installedDirectory = directory
    }

    func loadModel(named modelName: String) async throws {
        loadCount += 1
        directory = installedDirectory
    }

    func transcribe(samples: [Float], language: String) async throws -> String { "" }

    func unload() {
        unloadCount += 1
        directory = nil
    }

    func loadedModelDirectory() -> URL? { directory }
}
