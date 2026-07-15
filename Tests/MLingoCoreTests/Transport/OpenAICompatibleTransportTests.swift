import Foundation
import Testing
@testable import MLingoCore

@Test
func requestBuilderAppendsPathWithoutCorruptingBase() throws {
    let base = URL(string: "https://api.openai.com/v1")!
    let responses = try OpenAICompatibleRequestBuilder.completionURL(
        base: base,
        style: .responses
    )
    let chat = try OpenAICompatibleRequestBuilder.completionURL(
        base: base,
        style: .chatCompletions
    )
    #expect(responses.absoluteString == "https://api.openai.com/v1/responses")
    #expect(chat.absoluteString == "https://api.openai.com/v1/chat/completions")
    #expect(OpenAICompatibleRequestBuilder.modelsURL(base: base).path.hasSuffix("/models"))
}

@Test
func transportBuildsResponsesWireContract() async throws {
    let client = ScriptedTransportHTTPClient(outcomes: [
        .response(status: 200, data: TransportFixtures.responsesSuccess(), headers: [:]),
    ])
    let transport = OpenAICompatibleTransport(httpClient: client, retryDelay: { _ in })
    let profile = TransportFixtures.openAIProfile(style: .responses)
    let secret = "sk-test-secret"

    let result = try await transport.complete(
        OpenAICompatibleCompletionRequest(
            model: "gpt-test",
            instructions: "Translate to Vietnamese.",
            input: "Deploy it now.",
            maxOutputTokens: 2_048
        ),
        profile: profile,
        secretProvider: { _ in secret }
    )

    let request = try #require(client.requests.last)
    let body = try #require(request.jsonBody)
    #expect(result.text == TransportFixtures.translated)
    #expect(result.usage?.inputTokens == 11)
    #expect(result.usage?.outputTokens == 3)
    #expect(result.usage?.totalTokens == 14)
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(request.httpMethod == "POST")
    #expect(request.timeoutInterval == 8)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-secret")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(body["model"] as? String == "gpt-test")
    #expect(body["store"] as? Bool == false)
    #expect(body["max_output_tokens"] as? Int == 2_048)
    #expect(body["instructions"] as? String == "Translate to Vietnamese.")
    #expect(body["input"] as? String == "Deploy it now.")
    #expect(body["stream"] == nil)
    #expect(body["audio"] == nil)
}

@Test
func transportBuildsChatCompletionsWireContract() async throws {
    let client = ScriptedTransportHTTPClient(outcomes: [
        .response(status: 200, data: TransportFixtures.chatCompletionsSuccess(), headers: [:]),
    ])
    let transport = OpenAICompatibleTransport(httpClient: client, retryDelay: { _ in })
    let profile = TransportFixtures.openAIProfile(style: .chatCompletions)

    let result = try await transport.complete(
        OpenAICompatibleCompletionRequest(
            model: "gpt-test",
            instructions: "Translate to Vietnamese.",
            input: "Deploy it now.",
            maxOutputTokens: 2_048
        ),
        profile: profile,
        secretProvider: { _ in "sk-test" }
    )

    let request = try #require(client.requests.last)
    let body = try #require(request.jsonBody)
    let messages = try #require(body["messages"] as? [[String: String]])
    #expect(result.text == TransportFixtures.translated)
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    #expect(body["model"] as? String == "gpt-test")
    #expect(body["max_tokens"] as? Int == 2_048)
    #expect(body["stream"] as? Bool == false)
    #expect(body["store"] == nil)
    #expect(messages.count == 2)
    #expect(messages[0]["role"] == "system")
    #expect(messages[0]["content"] == "Translate to Vietnamese.")
    #expect(messages[1]["role"] == "user")
    #expect(messages[1]["content"] == "Deploy it now.")
}

@Test
func sameFixtureSucceedsThroughBothAPIStyles() async throws {
    let completion = OpenAICompatibleCompletionRequest(
        model: "gpt-test",
        instructions: "Translate.",
        input: "Hello",
        maxOutputTokens: 64
    )

    for style in [ProviderAPIStyle.responses, .chatCompletions] {
        let data = style == .responses
            ? TransportFixtures.responsesSuccess()
            : TransportFixtures.chatCompletionsSuccess()
        let client = ScriptedTransportHTTPClient(outcomes: [
            .response(status: 200, data: data, headers: [:]),
        ])
        let transport = OpenAICompatibleTransport(httpClient: client, retryDelay: { _ in })
        let result = try await transport.complete(
            completion,
            profile: TransportFixtures.openAIProfile(style: style),
            secretProvider: { _ in "sk-test" }
        )
        #expect(result.text == TransportFixtures.translated)
    }
}

@Test
func transportAppliesNoneBearerAndCustomHeaderAuth() async throws {
    let cases: [(ProviderAuthentication, (URLRequest) -> Bool)] = [
        (.none, { $0.value(forHTTPHeaderField: "Authorization") == nil }),
        (
            .bearer(credentialID: CredentialID("bearer-id")),
            { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret-value" }
        ),
        (
            .customHeader(name: "X-Api-Key", credentialID: CredentialID("header-id")),
            {
                $0.value(forHTTPHeaderField: "X-Api-Key") == "secret-value"
                    && $0.value(forHTTPHeaderField: "Authorization") == nil
            }
        ),
    ]

    for (auth, assertHeaders) in cases {
        let client = ScriptedTransportHTTPClient(outcomes: [
            .response(status: 200, data: TransportFixtures.chatCompletionsSuccess(), headers: [:]),
        ])
        let transport = OpenAICompatibleTransport(httpClient: client, retryDelay: { _ in })
        let profile = TransportFixtures.loopbackProfile(auth: auth)
        _ = try await transport.complete(
            OpenAICompatibleCompletionRequest(
                model: "local-model",
                instructions: "sys",
                input: "hi",
                maxOutputTokens: 16
            ),
            profile: profile,
            secretProvider: { _ in "secret-value" }
        )
        let request = try #require(client.requests.last)
        #expect(assertHeaders(request))
    }
}

@Test
func transportRequiresSecretForBearerAndCustomHeader() async throws {
    let transport = OpenAICompatibleTransport(
        httpClient: ScriptedTransportHTTPClient(outcomes: []),
        retryDelay: { _ in }
    )
    await #expect(throws: MLingoError.missingAPIKey) {
        _ = try await transport.complete(
            OpenAICompatibleCompletionRequest(
                model: "m",
                instructions: "i",
                input: "x",
                maxOutputTokens: 1
            ),
            profile: TransportFixtures.openAIProfile(
                auth: .bearer(credentialID: CredentialID("missing"))
            ),
            secretProvider: { _ in nil }
        )
    }
    await #expect(throws: MLingoError.missingAPIKey) {
        _ = try await transport.complete(
            OpenAICompatibleCompletionRequest(
                model: "m",
                instructions: "i",
                input: "x",
                maxOutputTokens: 1
            ),
            profile: TransportFixtures.loopbackProfile(
                auth: .customHeader(name: "X-Api-Key", credentialID: CredentialID("missing"))
            ),
            secretProvider: { _ in "  " }
        )
    }
}

@Test(arguments: [
    (401, #"{"error":{"code":"invalid_api_key","message":"Bad key"}}"#, MLingoError.invalidAPIKey),
    (404, #"{"error":{"code":"model_not_found","message":"Unknown"}}"#, MLingoError.invalidOpenAIModel),
    (429, #"{"error":{"code":"insufficient_quota","message":"No quota","type":"insufficient_quota"}}"#, MLingoError.quotaExceeded),
    (400, #"{"error":{"code":"invalid_request_error","message":"Bad request"}}"#, MLingoError.translationRequestRejected("Bad request")),
])
func transportMapsPermanentAPIErrors(
    status: Int,
    body: String,
    expected: MLingoError
) async throws {
    let client = ScriptedTransportHTTPClient(outcomes: [
        .response(status: status, data: Data(body.utf8), headers: [:]),
    ])
    let transport = OpenAICompatibleTransport(httpClient: client, retryDelay: { _ in })
    await #expect(throws: expected) {
        _ = try await transport.complete(
            OpenAICompatibleCompletionRequest(
                model: "m",
                instructions: "i",
                input: "x",
                maxOutputTokens: 1
            ),
            profile: TransportFixtures.openAIProfile(),
            secretProvider: { _ in "sk" }
        )
    }
    #expect(client.requests.count == 1)
}

@Test
func transportRetriesRateLimitOnce() async throws {
    let client = ScriptedTransportHTTPClient(outcomes: [
        .response(
            status: 429,
            data: Data(#"{"error":{"code":"rate_limit_exceeded","message":"Slow"}}"#.utf8),
            headers: ["Retry-After": "10"]
        ),
        .response(status: 200, data: TransportFixtures.responsesSuccess(), headers: [:]),
    ])
    let delays = TransportDelayRecorder()
    let transport = OpenAICompatibleTransport(
        httpClient: client,
        retryDelay: { seconds in await delays.record(seconds) }
    )

    let result = try await transport.complete(
        OpenAICompatibleCompletionRequest(
            model: "m",
            instructions: "i",
            input: "x",
            maxOutputTokens: 1
        ),
        profile: TransportFixtures.openAIProfile(),
        secretProvider: { _ in "sk" }
    )
    #expect(result.text == TransportFixtures.translated)
    #expect(client.requests.count == 2)
    #expect(await delays.values == [10])
}

@Test(arguments: [ProviderAPIStyle.responses, .chatCompletions])
func responseParserPropagatesRecognizedErrorPayload(style: ProviderAPIStyle) {
    #expect(throws: MLingoError.invalidAPIKey) {
        _ = try OpenAICompatibleResponseParser.parse(
            data: Data(#"{"object":"error","error":{"code":"invalid_api_key","message":"Bad key"}}"#.utf8),
            style: style
        )
    }
}

@Test
func responseParserPropagatesTopLevelObjectError() {
    #expect(throws: MLingoError.invalidOpenAIModel) {
        _ = try OpenAICompatibleResponseParser.parse(
            data: Data(#"{"object":"error","code":"model_not_found","message":"Missing model"}"#.utf8),
            style: .responses
        )
    }
}

@Test
func transportRejectsMalformedAndStreamedPayloads() async throws {
    let malformed = ScriptedTransportHTTPClient(outcomes: [
        .response(status: 200, data: Data("not-json".utf8), headers: [:]),
    ])
    await #expect(throws: MLingoError.invalidResponse) {
        _ = try await OpenAICompatibleTransport(httpClient: malformed, retryDelay: { _ in })
            .complete(
                OpenAICompatibleCompletionRequest(
                    model: "m",
                    instructions: "i",
                    input: "x",
                    maxOutputTokens: 1
                ),
                profile: TransportFixtures.openAIProfile(),
                secretProvider: { _ in "sk" }
            )
    }

    let streamed = ScriptedTransportHTTPClient(outcomes: [
        .response(status: 200, data: TransportFixtures.chatCompletionsStreamChunk(), headers: [:]),
    ])
    await #expect(throws: MLingoError.invalidResponse) {
        _ = try await OpenAICompatibleTransport(httpClient: streamed, retryDelay: { _ in })
            .complete(
                OpenAICompatibleCompletionRequest(
                    model: "m",
                    instructions: "i",
                    input: "x",
                    maxOutputTokens: 1
                ),
                profile: TransportFixtures.openAIProfile(style: .chatCompletions),
                secretProvider: { _ in "sk" }
            )
    }
}

@Test
func transportMapsNetworkErrorsWithoutRetry() async throws {
    let client = ScriptedTransportHTTPClient(outcomes: [
        .failure(URLError(.timedOut)),
    ])
    await #expect(throws: MLingoError.requestTimedOut) {
        _ = try await OpenAICompatibleTransport(httpClient: client, retryDelay: { _ in })
            .complete(
                OpenAICompatibleCompletionRequest(
                    model: "m",
                    instructions: "i",
                    input: "x",
                    maxOutputTokens: 1
                ),
                profile: TransportFixtures.openAIProfile(),
                secretProvider: { _ in "sk" }
            )
    }
    #expect(client.requests.count == 1)
}

@Test
func transportRefusesInvalidRemoteHTTPBeforeNetwork() async throws {
    let client = ScriptedTransportHTTPClient(outcomes: [])
    let profile = ProviderProfile(
        id: UUID(),
        name: "Bad",
        kind: .custom,
        endpoint: URL(string: "http://example.com/v1")!,
        apiStyle: .chatCompletions,
        authentication: .none,
        models: [.translation: ["m"]]
    )
    await #expect(throws: MLingoError.self) {
        _ = try await OpenAICompatibleTransport(httpClient: client, retryDelay: { _ in })
            .complete(
                OpenAICompatibleCompletionRequest(
                    model: "m",
                    instructions: "i",
                    input: "x",
                    maxOutputTokens: 1
                ),
                profile: profile,
                secretProvider: { _ in nil }
            )
    }
    #expect(client.requests.isEmpty)
}

@Test
func translationEngineUsesTransportForLegacyResponsesPath() async throws {
    let client = ScriptedTransportHTTPClient(outcomes: [
        .response(status: 200, data: TransportFixtures.responsesSuccess(), headers: [:]),
    ])
    let engine = OpenAITranslationEngine(
        apiKeyStore: TransportAPIKeyStore(apiKey: "  sk-test  "),
        httpClient: client
    )
    let item = try await engine.translate(
        TranslationRequest(
            current: Transcript(text: "  Deploy it now.  ", timestamp: 10),
            context: [
                Transcript(text: String(repeating: "a", count: 1_500), timestamp: 1),
                Transcript(text: String(repeating: "b", count: 1_100), timestamp: 4),
            ]
        ),
        settings: AppSettings(
            openAIModel: "gpt-test",
            sourceLanguage: "English",
            targetLanguage: "Vietnamese"
        )
    )
    let request = try #require(client.requests.last)
    let body = try #require(request.jsonBody)
    let input = try #require(body["input"] as? String)
    #expect(item.translated == TransportFixtures.translated)
    #expect(item.original == "Deploy it now.")
    #expect(request.url?.absoluteString.hasSuffix("/responses") == true)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    #expect(body["store"] as? Bool == false)
    #expect(!input.contains(String(repeating: "a", count: 100)))
    #expect(input.contains(String(repeating: "b", count: 100)))
}

@Test
func transportPropagatesCancellationWithoutRetry() async throws {
    let client = CancellingTransportHTTPClient()
    let transport = OpenAICompatibleTransport(httpClient: client, retryDelay: { _ in })
    await #expect(throws: CancellationError.self) {
        _ = try await transport.complete(
            OpenAICompatibleCompletionRequest(
                model: "m",
                instructions: "i",
                input: "x",
                maxOutputTokens: 1
            ),
            profile: TransportFixtures.openAIProfile(),
            secretProvider: { _ in "sk" }
        )
    }
    #expect(client.requestCount == 1)
}

@Test
func errorMapperMessagesAreProviderNeutral() {
    #expect(
        OpenAICompatibleErrorMapper.mapHTTPError(
            data: Data(#"{"error":{"code":"model_not_found"}}"#.utf8),
            statusCode: 404
        ) == .invalidOpenAIModel
    )
    #expect(
        MLingoError.invalidOpenAIModel.localizedDescription.contains("OpenAI") == false
    )
    #expect(
        MLingoError.invalidAPIKey.localizedDescription.contains("OpenAI") == false
    )
    #expect(
        MLingoError.requestTimedOut.localizedDescription.contains("OpenAI") == false
    )
    #expect(
        OpenAICompatibleErrorMapper.mapHTTPError(
            data: Data(#"{"error":{"code":"route_not_found","message":"Missing route"}}"#.utf8),
            statusCode: 404
        ) == .translationRequestRejected("Missing route")
    )
    let rejected = OpenAICompatibleErrorMapper.mapHTTPError(
        data: Data(),
        statusCode: 418
    )
    if case .translationRequestRejected(let message) = rejected {
        #expect(message.contains("translation provider"))
        #expect(!message.contains("OpenAI"))
    } else {
        Issue.record("Expected translationRequestRejected fallback")
    }
}

@Test
func profileAwareEngineTranslatesViaChatCompletions() async throws {
    let client = ScriptedTransportHTTPClient(outcomes: [
        .response(status: 200, data: TransportFixtures.chatCompletionsSuccess(), headers: [:]),
    ])
    let profile = TransportFixtures.loopbackProfile()
    let engine = OpenAITranslationEngine(
        profile: profile,
        secretProvider: { _ in nil },
        httpClient: client
    )
    let item = try await engine.translate(
        TranslationRequest(current: Transcript(text: "Hello", timestamp: 1)),
        settings: AppSettings(
            openAIModel: "local-model",
            sourceLanguage: "English",
            targetLanguage: "Vietnamese"
        )
    )
    #expect(item.translated == TransportFixtures.translated)
    #expect(client.requests.last?.url?.absoluteString.hasSuffix("/chat/completions") == true)
}

private actor TransportDelayRecorder {
    private(set) var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}

private final class TransportAPIKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    private var apiKey: String?
    init(apiKey: String?) { self.apiKey = apiKey }
    func loadAPIKey() throws -> String? { apiKey }
    func saveAPIKey(_ apiKey: String) throws { self.apiKey = apiKey }
    func deleteAPIKey() throws { apiKey = nil }
}

private final class CancellingTransportHTTPClient: HTTPClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requestCount = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { requestCount += 1 }
        throw CancellationError()
    }
}
