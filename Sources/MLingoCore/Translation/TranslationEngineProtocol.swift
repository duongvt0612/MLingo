import Foundation

public struct TranslationRequest: Equatable, Sendable {
    public let current: Transcript
    public let context: [Transcript]

    public init(current: Transcript, context: [Transcript] = []) {
        self.current = current
        self.context = context
    }
}

public protocol TranslationEngineProtocol: AnyObject, Sendable {
    func translate(_ request: TranslationRequest, settings: AppSettings) async throws -> SubtitleItem
    func translate(
        _ request: TranslationRequest,
        settings: AppSettings,
        selection: ResolvedProviderSelection?
    ) async throws -> SubtitleItem
}

public extension TranslationEngineProtocol {
    func translate(
        _ request: TranslationRequest,
        settings: AppSettings,
        selection: ResolvedProviderSelection?
    ) async throws -> SubtitleItem {
        try await translate(request, settings: settings)
    }
}
