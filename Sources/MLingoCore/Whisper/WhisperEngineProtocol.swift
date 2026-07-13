import Foundation

public protocol WhisperEngineProtocol: AnyObject, Sendable {
    func loadModel(named modelName: String) async throws
    func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript?
}
