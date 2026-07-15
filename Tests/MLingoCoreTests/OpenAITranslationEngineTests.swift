import Foundation
import Testing
@testable import MLingoCore

@Test
func translationEngineRequiresAPIKey() async throws {
    let engine = OpenAITranslationEngine(
        apiKeyStore: InMemoryAPIKeyStore(apiKey: nil),
        httpClient: ScriptedHTTPClient(outcomes: [])
    )

    await #expect(throws: MLingoError.missingAPIKey) {
        _ = try await engine.translate(
            TranslationRequest(current: Transcript(text: "Hello", timestamp: 0)),
            settings: AppSettings()
        )
    }
}

@Test
func translationEngineBuildsPrivateBoundedContextRequest() async throws {
    let client = ScriptedHTTPClient(outcomes: [
        .response(status: 200, data: responseData("Xin chào"))
    ])
    let engine = OpenAITranslationEngine(
        apiKeyStore: InMemoryAPIKeyStore(apiKey: "  sk-test  "),
        httpClient: client
    )
    let request = TranslationRequest(
        current: Transcript(text: "  Deploy it now.  ", timestamp: 10),
        context: [
            Transcript(text: String(repeating: "a", count: 1_500), timestamp: 1),
            Transcript(text: String(repeating: "b", count: 1_100), timestamp: 4),
        ]
    )

    let item = try await engine.translate(
        request,
        settings: AppSettings(
            openAIModel: "gpt-test",
            sourceLanguage: "English",
            targetLanguage: "Vietnamese"
        )
    )

    let sentRequest = try #require(client.requests.last)
    let body = try #require(sentRequest.jsonBody)
    let input = try #require(body["input"] as? String)
    #expect(item.translated == "Xin chào")
    #expect(item.original == "Deploy it now.")
    #expect(item.start == 10)
    #expect(sentRequest.timeoutInterval == 8)
    #expect(sentRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    #expect(body["model"] as? String == "gpt-test")
    #expect(body["store"] as? Bool == false)
    #expect(body["max_output_tokens"] as? Int == 2_048)
    #expect(body["stream"] == nil)
    #expect(body["audio"] == nil)
    #expect(!input.contains(String(repeating: "a", count: 100)))
    #expect(input.contains(String(repeating: "b", count: 100)))
    #expect(input.contains("Deploy it now."))
    #expect(input.contains("Translate only CURRENT SUBTITLE"))
}

@Test
func translationEngineRejectsInvalidLocalInputBeforeNetwork() async throws {
    let client = ScriptedHTTPClient(outcomes: [])
    let engine = OpenAITranslationEngine(
        apiKeyStore: InMemoryAPIKeyStore(apiKey: "sk-test"),
        httpClient: client
    )

    await #expect(throws: MLingoError.invalidOpenAIModel) {
        _ = try await engine.translate(
            TranslationRequest(current: Transcript(text: "Hello", timestamp: 0)),
            settings: AppSettings(openAIModel: "   ")
        )
    }
    await #expect(throws: MLingoError.translationInputTooLong(maxCharacters: 2_000)) {
        _ = try await engine.translate(
            TranslationRequest(
                current: Transcript(text: String(repeating: "x", count: 2_001), timestamp: 0)
            ),
            settings: AppSettings()
        )
    }
    #expect(client.requests.isEmpty)
}

@Test(arguments: [
    (401, #"{"error":{"code":"invalid_api_key","message":"Bad key","type":"invalid_request_error"}}"#, MLingoError.invalidAPIKey),
    (404, #"{"error":{"code":"model_not_found","message":"Unknown model","type":"invalid_request_error"}}"#, MLingoError.invalidOpenAIModel),
    (429, #"{"error":{"code":"insufficient_quota","message":"No quota","type":"insufficient_quota"}}"#, MLingoError.quotaExceeded),
    (429, #"{"error":{"code":"billing_hard_limit_reached","message":"Billing limit"}}"#, MLingoError.quotaExceeded),
    (400, #"{"error":{"code":"invalid_request_error","message":"Bad request"}}"#, MLingoError.translationRequestRejected("Bad request")),
])
func translationEngineMapsPermanentAPIErrors(
    status: Int,
    body: String,
    expected: MLingoError
) async throws {
    let client = ScriptedHTTPClient(outcomes: [
        .response(status: status, data: Data(body.utf8))
    ])
    let engine = OpenAITranslationEngine(
        apiKeyStore: InMemoryAPIKeyStore(apiKey: "sk-test"),
        httpClient: client
    )

    await #expect(throws: expected) {
        _ = try await engine.translate(
            TranslationRequest(current: Transcript(text: "Hello", timestamp: 0)),
            settings: AppSettings()
        )
    }
    #expect(client.requests.count == 1)
}

@Test
func translationEngineRetriesRateLimitOnceAndHonorsCappedRetryAfter() async throws {
    let client = ScriptedHTTPClient(outcomes: [
        .response(
            status: 429,
            data: Data(#"{"error":{"code":"rate_limit_exceeded","message":"Slow down"}}"#.utf8),
            headers: ["Retry-After": "10"]
        ),
        .response(status: 200, data: responseData("Xin chào")),
    ])
    let delays = DelayRecorder()
    let engine = OpenAITranslationEngine(
        apiKeyStore: InMemoryAPIKeyStore(apiKey: "sk-test"),
        httpClient: client,
        retryDelay: { seconds in await delays.record(seconds) }
    )

    let item = try await engine.translate(
        TranslationRequest(current: Transcript(text: "Hello", timestamp: 0)),
        settings: AppSettings()
    )

    #expect(item.translated == "Xin chào")
    #expect(client.requests.count == 2)
    #expect(await delays.values == [10])
}

@Test(arguments: [500, 501, 599])
func translationEngineRetriesEveryServerFailureOnlyOnce(status: Int) async throws {
    let failure = Data(#"{"error":{"code":"server_error","message":"Unavailable"}}"#.utf8)
    let client = ScriptedHTTPClient(outcomes: [
        .response(status: status, data: failure),
        .response(status: status, data: failure),
    ])
    let engine = OpenAITranslationEngine(
        apiKeyStore: InMemoryAPIKeyStore(apiKey: "sk-test"),
        httpClient: client,
        retryDelay: { _ in }
    )

    await #expect(throws: MLingoError.translationServiceUnavailable) {
        _ = try await engine.translate(
            TranslationRequest(current: Transcript(text: "Hello", timestamp: 0)),
            settings: AppSettings()
        )
    }
    #expect(client.requests.count == 2)
}

@Test(arguments: [
    (URLError.Code.notConnectedToInternet, MLingoError.networkOffline),
    (URLError.Code.timedOut, MLingoError.requestTimedOut),
])
func translationEngineMapsNetworkErrorsWithoutRetry(
    code: URLError.Code,
    expected: MLingoError
) async throws {
    let client = ScriptedHTTPClient(outcomes: [.failure(URLError(code))])
    let engine = OpenAITranslationEngine(
        apiKeyStore: InMemoryAPIKeyStore(apiKey: "sk-test"),
        httpClient: client
    )

    await #expect(throws: expected) {
        _ = try await engine.translate(
            TranslationRequest(current: Transcript(text: "Hello", timestamp: 0)),
            settings: AppSettings()
        )
    }
    #expect(client.requests.count == 1)
}

private func responseData(_ text: String) -> Data {
    Data(#"{"status":"completed","output_text":"\#(text)"}"#.utf8)
}

private final class InMemoryAPIKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    private var apiKey: String?

    init(apiKey: String?) {
        self.apiKey = apiKey
    }

    func loadAPIKey() throws -> String? { apiKey }
    func saveAPIKey(_ apiKey: String) throws { self.apiKey = apiKey }
    func deleteAPIKey() throws { apiKey = nil }
}

private enum HTTPOutcome {
    case response(status: Int, data: Data, headers: [String: String] = [:])
    case failure(any Error)
}

private final class ScriptedHTTPClient: HTTPClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [HTTPOutcome]
    private(set) var requests: [URLRequest] = []

    init(outcomes: [HTTPOutcome]) {
        self.outcomes = outcomes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try lock.withLock {
            requests.append(request)
            let outcome = outcomes.removeFirst()
            switch outcome {
            case .response(let status, let data, let headers):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: headers
                )!
                return (data, response)
            case .failure(let error):
                throw error
            }
        }
    }
}

private actor DelayRecorder {
    private(set) var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}
