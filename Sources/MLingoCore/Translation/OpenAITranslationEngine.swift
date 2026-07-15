import Foundation

public protocol HTTPClientProtocol: AnyObject, Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClientProtocol {}

public final class OpenAITranslationEngine: TranslationEngineProtocol, @unchecked Sendable {
    public typealias RetryDelay = @Sendable (TimeInterval) async throws -> Void

    static let maximumCurrentCharacters = 2_000
    static let maximumContextCharacters = 2_000
    static let maximumContextItems = 2
    static let requestTimeout: TimeInterval = 8
    static let maximumOutputTokens = 2_048

    private let apiKeyStore: APIKeyStoreProtocol?
    private let profile: ProviderProfile
    private let secretProvider: @Sendable (CredentialID) throws -> String?
    private let transport: any OpenAICompatibleTransporting

    /// Legacy convenience initializer used by existing call sites and tests.
    /// Uses Responses style at the given full endpoint URL (including `/responses`).
    public init(
        apiKeyStore: APIKeyStoreProtocol,
        httpClient: HTTPClientProtocol = URLSession.shared,
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        retryDelay: @escaping RetryDelay = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.apiKeyStore = apiKeyStore
        let base = Self.baseEndpoint(fromCompletionURL: endpoint)
        self.profile = ProviderProfile(
            id: ProviderDefaults.openAIProfileID,
            name: "OpenAI",
            kind: .openAI,
            endpoint: base,
            apiStyle: .responses,
            authentication: .bearer(credentialID: ProviderDefaults.openAICredentialID),
            models: [:]
        )
        self.secretProvider = { _ in try apiKeyStore.loadAPIKey() }
        self.transport = OpenAICompatibleTransport(
            httpClient: httpClient,
            timeout: Self.requestTimeout,
            retryDelay: retryDelay
        )
    }

    public init(
        profile: ProviderProfile,
        secretProvider: @escaping @Sendable (CredentialID) throws -> String?,
        httpClient: HTTPClientProtocol = URLSession.shared,
        timeout: TimeInterval = 8,
        retryDelay: @escaping RetryDelay = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.apiKeyStore = nil
        self.profile = profile
        self.secretProvider = secretProvider
        self.transport = OpenAICompatibleTransport(
            httpClient: httpClient,
            timeout: timeout,
            retryDelay: retryDelay
        )
    }

    public init(
        profile: ProviderProfile,
        secretProvider: @escaping @Sendable (CredentialID) throws -> String?,
        transport: any OpenAICompatibleTransporting
    ) {
        self.apiKeyStore = nil
        self.profile = profile
        self.secretProvider = secretProvider
        self.transport = transport
    }

    public func translate(
        _ translationRequest: TranslationRequest,
        settings: AppSettings
    ) async throws -> SubtitleItem {
        let model = settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw MLingoError.invalidOpenAIModel }
        guard !settings.sourceLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MLingoError.invalidTranslationConfiguration("Add a source language in Settings.")
        }
        guard !settings.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MLingoError.invalidTranslationConfiguration("Add a target language in Settings.")
        }

        let currentText = translationRequest.current.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentText.isEmpty else {
            throw MLingoError.invalidTranslationConfiguration("Transcript text is empty.")
        }
        guard currentText.count <= Self.maximumCurrentCharacters else {
            throw MLingoError.translationInputTooLong(
                maxCharacters: Self.maximumCurrentCharacters
            )
        }

        let contextTexts = boundedContext(from: translationRequest.context)
        let completion = OpenAICompatibleCompletionRequest(
            model: model,
            instructions: TranslationPromptBuilder.instructions(settings: settings),
            input: TranslationPromptBuilder.input(
                currentText: currentText,
                contextTexts: contextTexts
            ),
            maxOutputTokens: Self.maximumOutputTokens
        )

        // Validate API key early for legacy bearer path when store is present.
        if apiKeyStore != nil {
            _ = try validatedAPIKey()
        }

        let result = try await transport.complete(
            completion,
            profile: profile,
            secretProvider: secretProvider
        )
        return SubtitleItem(
            original: currentText,
            translated: result.text,
            start: translationRequest.current.timestamp,
            end: translationRequest.current.timestamp + 3
        )
    }

    private func validatedAPIKey() throws -> String {
        let apiKey = try apiKeyStore?.loadAPIKey()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let apiKey, !apiKey.isEmpty else {
            throw MLingoError.missingAPIKey
        }
        return apiKey
    }

    private func boundedContext(from transcripts: [Transcript]) -> [String] {
        var remaining = Self.maximumContextCharacters
        var selected: [String] = []

        for transcript in transcripts.suffix(Self.maximumContextItems).reversed() {
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= remaining else { continue }
            selected.append(text)
            remaining -= text.count
        }
        return selected.reversed()
    }

    /// Strips a trailing `/responses` or `/chat/completions` segment to recover the base endpoint.
    static func baseEndpoint(fromCompletionURL url: URL) -> URL {
        var path = url.absoluteString
        while path.hasSuffix("/") {
            path.removeLast()
        }
        for suffix in ["/responses", "/chat/completions"] {
            if path.lowercased().hasSuffix(suffix) {
                path = String(path.dropLast(suffix.count))
                while path.hasSuffix("/") {
                    path.removeLast()
                }
                return URL(string: path) ?? url
            }
        }
        return url
    }
}
