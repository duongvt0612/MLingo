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

    private let apiKeyStore: APIKeyStoreProtocol
    private let httpClient: HTTPClientProtocol
    private let endpoint: URL
    private let retryDelay: RetryDelay

    public init(
        apiKeyStore: APIKeyStoreProtocol,
        httpClient: HTTPClientProtocol = URLSession.shared,
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        retryDelay: @escaping RetryDelay = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.apiKeyStore = apiKeyStore
        self.httpClient = httpClient
        self.endpoint = endpoint
        self.retryDelay = retryDelay
    }

    public func translate(
        _ translationRequest: TranslationRequest,
        settings: AppSettings
    ) async throws -> SubtitleItem {
        let apiKey = try validatedAPIKey()
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
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "instructions": TranslationPromptBuilder.instructions(settings: settings),
            "input": TranslationPromptBuilder.input(
                currentText: currentText,
                contextTexts: contextTexts
            ),
            "store": false,
            "max_output_tokens": Self.maximumOutputTokens,
        ])

        let data = try await perform(request)
        let translated = try TranslationResponseParser.parse(data: data)
        return SubtitleItem(
            original: currentText,
            translated: translated,
            start: translationRequest.current.timestamp,
            end: translationRequest.current.timestamp + 3
        )
    }

    private func validatedAPIKey() throws -> String {
        let apiKey = try apiKeyStore.loadAPIKey()?
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

    private func perform(_ request: URLRequest) async throws -> Data {
        for attempt in 0...1 {
            do {
                let (data, response) = try await httpClient.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw MLingoError.invalidResponse
                }
                guard !(200..<300).contains(httpResponse.statusCode) else { return data }

                let mapped = TranslationResponseParser.apiError(
                    data: data,
                    statusCode: httpResponse.statusCode
                )
                logAPIError(mapped, response: httpResponse)
                if attempt == 0, shouldRetry(mapped, statusCode: httpResponse.statusCode) {
                    try await retryDelay(retryDelaySeconds(from: httpResponse))
                    continue
                }
                throw mapped
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MLingoError {
                throw error
            } catch let error as URLError {
                switch error.code {
                case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                    throw MLingoError.networkOffline
                case .timedOut:
                    throw MLingoError.requestTimedOut
                case .cancelled:
                    throw CancellationError()
                default:
                    throw MLingoError.translationFailed(error.localizedDescription)
                }
            } catch {
                throw MLingoError.translationFailed(error.localizedDescription)
            }
        }
        throw MLingoError.translationServiceUnavailable
    }

    private func shouldRetry(_ error: MLingoError, statusCode: Int) -> Bool {
        error == .rateLimited || (500..<600).contains(statusCode)
    }

    private func retryDelaySeconds(from response: HTTPURLResponse) -> TimeInterval {
        guard
            let value = response.value(forHTTPHeaderField: "Retry-After"),
            let seconds = TimeInterval(value),
            seconds.isFinite,
            seconds >= 0
        else {
            return 0.25
        }
        return min(seconds, 1)
    }

    private func logAPIError(_ error: MLingoError, response: HTTPURLResponse) {
        let requestID = response.value(forHTTPHeaderField: "x-request-id") ?? "unavailable"
        MLingoLogger.translation.error(
            "OpenAI request failed HTTP \(response.statusCode, privacy: .public), code \(error.diagnosticCode, privacy: .public), request ID \(requestID, privacy: .public)"
        )
    }
}

private extension MLingoError {
    var diagnosticCode: String {
        switch self {
        case .missingAPIKey: "missing_api_key"
        case .invalidAPIKey: "invalid_api_key"
        case .invalidOpenAIModel: "invalid_model"
        case .quotaExceeded: "quota_exceeded"
        case .rateLimited: "rate_limited"
        case .networkOffline: "network_offline"
        case .requestTimedOut: "request_timed_out"
        case .translationServiceUnavailable: "service_unavailable"
        case .translationInputTooLong: "input_too_long"
        case .invalidTranslationConfiguration: "invalid_configuration"
        case .translationRequestRejected: "request_rejected"
        case .invalidResponse: "invalid_response"
        case .translationFailed: "translation_failed"
        default: "non_translation_error"
        }
    }
}
