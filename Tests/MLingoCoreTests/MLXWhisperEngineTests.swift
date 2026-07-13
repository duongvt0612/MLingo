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
