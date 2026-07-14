import Foundation
import Testing
@testable import MLingoCore

@Test
func mlxWhisperEngineReusesLoadedModelAndReloadsChanges() async throws {
    let backend = StubWhisperBackend(transcripts: ["Hello"])
    let engine = MLXWhisperEngine(backend: backend)

    try await engine.loadModel(named: "model-a")
    try await engine.loadModel(named: "model-a")
    try await engine.loadModel(named: "model-b")

    #expect(await backend.loadedModelNames == ["model-a", "model-b"])
}

@Test
func mlxWhisperEngineRejectsBlankModelName() async {
    let engine = MLXWhisperEngine(backend: StubWhisperBackend(transcripts: []))

    await #expect(throws: MLingoError.self) {
        try await engine.loadModel(named: "  ")
    }
}

@Test
func mlxWhisperEnginePassesLanguageAndBuildsTranscript() async throws {
    let backend = StubWhisperBackend(transcripts: ["  Hello from MLX  "])
    let engine = MLXWhisperEngine(backend: backend)
    try await engine.loadModel(named: "model-a")

    let transcript = try await engine.transcribe(
        audioChunk(duration: 1, timestamp: 42),
        language: "English"
    )

    #expect(transcript?.text == "Hello from MLX")
    #expect(transcript?.timestamp == 42)
    #expect(await backend.languages == ["English"])
}

@Test
func mlxWhisperEngineDropsEmptyTranscript() async throws {
    let backend = StubWhisperBackend(transcripts: [" \n "])
    let engine = MLXWhisperEngine(backend: backend)
    try await engine.loadModel(named: "model-a")

    let transcript = try await engine.transcribe(
        audioChunk(duration: 1, timestamp: 0),
        language: "English"
    )

    #expect(transcript == nil)
}

@Test
func mlxBackendResolvesOnlyManagedLegacyMLXModelIDs() {
    #expect(
        MLXAudioWhisperBackend.resolvedModelName(
            for: "mlx-community/whisper-base-mlx"
        ) == "mlx-community/whisper-base-asr-fp16"
    )
    #expect(
        MLXAudioWhisperBackend.resolvedModelName(
            for: "mlx-community/whisper-small-mlx"
        ) == "mlx-community/whisper-small-asr-fp16"
    )
    #expect(
        MLXAudioWhisperBackend.resolvedModelName(
            for: "organization/custom-whisper"
        ) == "organization/custom-whisper"
    )
}

@Test
func mlxBackendUsesShortDecodeBudgetForLiveWindows() {
    #expect(MLXAudioWhisperBackend.maximumTokenCount(sampleCount: 24_000) == 48)
    #expect(MLXAudioWhisperBackend.maximumTokenCount(sampleCount: 64_000) == 64)
    #expect(MLXAudioWhisperBackend.maximumTokenCount(sampleCount: 480_000) == 128)
}

@Test
func mlxBackendRejectsMissingMetalLibraryBeforeLoadingModel() async {
    let backend = MLXAudioWhisperBackend(isMetalLibraryAvailable: { false })

    do {
        try await backend.loadModel(named: "mlx-community/whisper-base-mlx")
        Issue.record("Expected the backend to reject a build without MLX Metal resources")
    } catch let error as MLingoError {
        #expect(error.errorDescription?.contains("swift run") == true)
        #expect(error.errorDescription?.contains("MLingo scheme") == true)
    } catch {
        Issue.record("Expected MLingoError, received \(error)")
    }
}

@Test
func mlxMetalLibraryAvailabilityFindsXcodeResourceBundle() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "MLingo-Metal-\(UUID().uuidString)", directoryHint: .isDirectory)
    let resourceDirectory = root
        .appending(path: "mlx-swift_Cmlx.bundle", directoryHint: .isDirectory)
        .appending(path: "Contents/Resources", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(MLXMetalLibraryAvailability.isAvailable(searchRoots: [root]) == false)
    #expect(
        FileManager.default.createFile(
            atPath: resourceDirectory.appending(path: "default.metallib").path,
            contents: Data([0])
        )
    )
    #expect(MLXMetalLibraryAvailability.isAvailable(searchRoots: [root]))
}

@Test
func mlxMetalLibraryAvailabilityRejectsSwiftPMCommandLineBuildWithoutLibrary() {
    guard ProcessInfo.processInfo.arguments.first?.contains("/.build/") == true else {
        return
    }

    #expect(MLXMetalLibraryAvailability.isAvailable() == false)
}

@Test
func mlxMetalLibraryAvailabilityRejectsSwiftPMExecutableBeforeBundleSearch() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "MLingo-Metal-\(UUID().uuidString)", directoryHint: .isDirectory)
    let resourceDirectory = root
        .appending(path: "mlx-swift_Cmlx.bundle", directoryHint: .isDirectory)
        .appending(path: "Contents/Resources", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(
        FileManager.default.createFile(
            atPath: resourceDirectory.appending(path: "default.metallib").path,
            contents: Data([0])
        )
    )

    let swiftPMExecutable = root
        .appending(path: ".build/arm64-apple-macosx/debug/MLingo")
    #expect(
        MLXMetalLibraryAvailability.isAvailable(
            executableURL: swiftPMExecutable,
            searchRoots: [root]
        ) == false
    )
}

private actor StubWhisperBackend: WhisperInferenceBackend {
    private var transcripts: [String]
    private(set) var loadedModelNames: [String] = []
    private(set) var languages: [String] = []

    init(transcripts: [String]) {
        self.transcripts = transcripts
    }

    func loadModel(named modelName: String) async throws {
        loadedModelNames.append(modelName)
    }

    func transcribe(samples: [Float], language: String) async throws -> String {
        languages.append(language)
        return transcripts.isEmpty ? "" : transcripts.removeFirst()
    }
}

private func audioChunk(duration: TimeInterval, timestamp: TimeInterval) -> AudioChunk {
    AudioChunk(
        samples: Array(repeating: 0.05, count: Int(duration * 16_000)),
        sampleRate: 16_000,
        channelCount: 1,
        timestamp: timestamp,
        duration: duration
    )
}
