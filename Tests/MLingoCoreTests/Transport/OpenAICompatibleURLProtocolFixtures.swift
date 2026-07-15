import Foundation
@testable import MLingoCore

/// Shared offline HTTP script harness for transport tests.
/// Uses injectable `HTTPClientProtocol` (not Foundation `URLProtocol`) so production
/// code stays on the same seam as unit tests without protocol-class registration.
enum TransportHTTPOutcome: Sendable {
    case response(status: Int, data: Data, headers: [String: String])
    case failure(any Error)
}

final class ScriptedTransportHTTPClient: HTTPClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [TransportHTTPOutcome]
    private(set) var requests: [URLRequest] = []

    init(outcomes: [TransportHTTPOutcome]) {
        self.outcomes = outcomes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try lock.withLock {
            requests.append(request)
            guard !outcomes.isEmpty else {
                throw URLError(.badServerResponse)
            }
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

enum TransportFixtures {
    static let translated = "Xin chào"

    static func responsesSuccess(text: String = translated) -> Data {
        Data(#"{"status":"completed","output_text":"\#(text)","usage":{"input_tokens":11,"output_tokens":3,"total_tokens":14}}"#.utf8)
    }

    static func chatCompletionsSuccess(text: String = translated) -> Data {
        Data(#"{"id":"chatcmpl-1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"\#(text)"},"finish_reason":"stop"}],"usage":{"prompt_tokens":11,"completion_tokens":3,"total_tokens":14}}"#.utf8)
    }

    static func chatCompletionsStreamChunk() -> Data {
        Data(#"{"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#.utf8)
    }

    static func modelsList(_ ids: [String]) -> Data {
        let items = ids.map { #"{"id":"\#($0)","object":"model"}"# }.joined(separator: ",")
        return Data(#"{"object":"list","data":[\#(items)]}"#.utf8)
    }

    static func openAIProfile(
        style: ProviderAPIStyle = .responses,
        auth: ProviderAuthentication = .bearer(credentialID: CredentialID("test-secret"))
    ) -> ProviderProfile {
        ProviderProfile(
            id: UUID(),
            name: "OpenAI Test",
            kind: .openAI,
            endpoint: URL(string: "https://api.openai.com/v1")!,
            apiStyle: style,
            authentication: auth,
            models: [.translation: ["gpt-test"]]
        )
    }

    static func loopbackProfile(
        kind: ProviderKind = .ollama,
        endpoint: String = "http://127.0.0.1:11434/v1",
        style: ProviderAPIStyle = .chatCompletions,
        auth: ProviderAuthentication = .none
    ) -> ProviderProfile {
        ProviderProfile(
            id: UUID(),
            name: kind.rawValue,
            kind: kind,
            endpoint: URL(string: endpoint)!,
            apiStyle: style,
            authentication: auth,
            models: [.translation: ["local-model"]]
        )
    }
}

extension URLRequest {
    var jsonBody: [String: Any]? {
        guard let httpBody else { return nil }
        return try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any]
    }
}
