import Foundation

public protocol TranslationEngineProtocol: AnyObject, Sendable {
    func translate(_ transcript: Transcript, settings: AppSettings) async throws -> SubtitleItem
}
