import Foundation

public final class FixtureWhisperEngine: WhisperEngineProtocol, @unchecked Sendable {
    private var transcripts: [Transcript]

    public init(transcripts: [Transcript]) {
        self.transcripts = transcripts
    }

    public func loadModel(named modelName: String) async throws {}

    public func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript? {
        guard !transcripts.isEmpty else { return nil }
        return transcripts.removeFirst()
    }
}
