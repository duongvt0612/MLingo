import Foundation

public protocol HTTPClientProtocol: AnyObject, Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClientProtocol {}

public final class OpenAITranslationEngine: TranslationEngineProtocol, @unchecked Sendable {
    private let apiKeyStore: APIKeyStoreProtocol
    private let httpClient: HTTPClientProtocol
    private let endpoint: URL

    public init(
        apiKeyStore: APIKeyStoreProtocol,
        httpClient: HTTPClientProtocol = URLSession.shared,
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!
    ) {
        self.apiKeyStore = apiKeyStore
        self.httpClient = httpClient
        self.endpoint = endpoint
    }

    public func translate(_ transcript: Transcript, settings: AppSettings) async throws -> SubtitleItem {
        guard let apiKey = try apiKeyStore.loadAPIKey(), !apiKey.isEmpty else {
            throw MLingoError.missingAPIKey
        }

        let sourceText = TranslationPromptBuilder.input(for: transcript)
        guard !sourceText.isEmpty else {
            throw MLingoError.translationFailed("Transcript text is empty.")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": settings.openAIModel,
            "instructions": TranslationPromptBuilder.instructions(settings: settings),
            "input": sourceText
        ])

        let (data, response) = try await httpClient.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw MLingoError.translationFailed("OpenAI API returned HTTP \(httpResponse.statusCode).")
        }

        let translated = try TranslationResponseParser.parse(data: data)
        return SubtitleItem(
            original: transcript.text,
            translated: translated,
            start: transcript.timestamp,
            end: transcript.timestamp + 3
        )
    }
}
