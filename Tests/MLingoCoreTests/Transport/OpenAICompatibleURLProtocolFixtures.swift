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
        encode(ResponsesFixture(
            status: "completed",
            output_text: text,
            usage: ResponsesUsageFixture(
                input_tokens: 11,
                output_tokens: 3,
                total_tokens: 14
            )
        ))
    }

    static func chatCompletionsSuccess(text: String = translated) -> Data {
        encode(ChatCompletionFixture(
            id: "chatcmpl-1",
            object: "chat.completion",
            choices: [ChatChoiceFixture(
                index: 0,
                message: ChatMessageFixture(role: "assistant", content: text),
                finish_reason: "stop"
            )],
            usage: ChatUsageFixture(
                prompt_tokens: 11,
                completion_tokens: 3,
                total_tokens: 14
            )
        ))
    }

    static func chatCompletionsStreamChunk() -> Data {
        encode(ChatStreamFixture(
            id: "chatcmpl-1",
            object: "chat.completion.chunk",
            choices: [ChatStreamChoiceFixture(
                index: 0,
                delta: ChatDeltaFixture(content: "Hi")
            )]
        ))
    }

    static func modelsList(_ ids: [String]) -> Data {
        encode(ModelsListFixture(
            object: "list",
            data: ids.map { ModelFixture(id: $0, object: "model") }
        ))
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

    private static func encode<Value: Encodable>(_ value: Value) -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            preconditionFailure("Transport fixture encoding failed: \(error)")
        }
    }
}

private struct ResponsesFixture: Encodable {
    let status: String
    let output_text: String
    let usage: ResponsesUsageFixture
}

private struct ResponsesUsageFixture: Encodable {
    let input_tokens: Int
    let output_tokens: Int
    let total_tokens: Int
}

private struct ChatCompletionFixture: Encodable {
    let id: String
    let object: String
    let choices: [ChatChoiceFixture]
    let usage: ChatUsageFixture
}

private struct ChatChoiceFixture: Encodable {
    let index: Int
    let message: ChatMessageFixture
    let finish_reason: String
}

private struct ChatMessageFixture: Encodable {
    let role: String
    let content: String
}

private struct ChatUsageFixture: Encodable {
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int
}

private struct ChatStreamFixture: Encodable {
    let id: String
    let object: String
    let choices: [ChatStreamChoiceFixture]
}

private struct ChatStreamChoiceFixture: Encodable {
    let index: Int
    let delta: ChatDeltaFixture

    private enum CodingKeys: String, CodingKey {
        case index
        case delta
        case finish_reason
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(delta, forKey: .delta)
        try container.encodeNil(forKey: .finish_reason)
    }
}

private struct ChatDeltaFixture: Encodable {
    let content: String
}

private struct ModelsListFixture: Encodable {
    let object: String
    let data: [ModelFixture]
}

private struct ModelFixture: Encodable {
    let id: String
    let object: String
}

extension URLRequest {
    var jsonBody: [String: Any]? {
        guard let httpBody else { return nil }
        return try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any]
    }
}
