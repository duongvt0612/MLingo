import Foundation
import Testing
@testable import MLingoCore

@Test
func translationEngineRequiresAPIKey() async throws {
    let engine = OpenAITranslationEngine(
        apiKeyStore: InMemoryAPIKeyStore(apiKey: nil),
        httpClient: StubHTTPClient(data: Data())
    )

    await #expect(throws: MLingoError.missingAPIKey) {
        _ = try await engine.translate(
            Transcript(text: "Hello", timestamp: 0),
            settings: AppSettings()
        )
    }
}

@Test
func translationEngineBuildsRequestAndParsesResponse() async throws {
    let client = StubHTTPClient(data: #"{"output_text":"Xin chao"}"#.data(using: .utf8)!)
    let engine = OpenAITranslationEngine(
        apiKeyStore: InMemoryAPIKeyStore(apiKey: "sk-test"),
        httpClient: client
    )

    let item = try await engine.translate(
        Transcript(text: "Hello", timestamp: 10),
        settings: AppSettings(openAIModel: "gpt-test")
    )

    #expect(item.translated == "Xin chao")
    #expect(item.start == 10)
    #expect(client.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    #expect(client.lastBodyString?.contains("\"model\":\"gpt-test\"") == true)
}

private final class InMemoryAPIKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    private var apiKey: String?

    init(apiKey: String?) {
        self.apiKey = apiKey
    }

    func loadAPIKey() throws -> String? {
        apiKey
    }

    func saveAPIKey(_ apiKey: String) throws {
        self.apiKey = apiKey
    }

    func deleteAPIKey() throws {
        apiKey = nil
    }
}

private final class StubHTTPClient: HTTPClientProtocol, @unchecked Sendable {
    let data: Data
    private(set) var lastRequest: URLRequest?
    var lastBodyString: String? {
        lastRequest?.httpBody.flatMap { String(data: $0, encoding: .utf8) }
    }

    init(data: Data) {
        self.data = data
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
