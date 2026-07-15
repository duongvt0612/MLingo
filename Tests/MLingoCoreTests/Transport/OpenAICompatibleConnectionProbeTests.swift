import Foundation
import Testing
@testable import MLingoCore

@Test
func connectionProbeDiscoversModelsFromModelsEndpoint() async throws {
    let client = ScriptedTransportHTTPClient(outcomes: [
        .response(
            status: 200,
            data: TransportFixtures.modelsList(["llama3", "mistral"]),
            headers: [:]
        ),
    ])
    let probe = OpenAICompatibleConnectionProbe(httpClient: client)
    let result = try await probe.testConnection(
        profile: TransportFixtures.loopbackProfile(),
        secretProvider: { _ in nil }
    )
    #expect(result.succeeded)
    #expect(result.models == ["llama3", "mistral"])
    #expect(client.requests.last?.httpMethod == "GET")
    #expect(client.requests.last?.url?.absoluteString.hasSuffix("/models") == true)
}

@Test
func connectionProbeFallsBackToCompletionWhenModelsMissing() async throws {
    let client = ScriptedTransportHTTPClient(outcomes: [
        .response(status: 404, data: Data(#"{"error":{"message":"not found"}}"#.utf8), headers: [:]),
        .response(status: 200, data: TransportFixtures.chatCompletionsSuccess(text: "OK"), headers: [:]),
    ])
    let probe = OpenAICompatibleConnectionProbe(httpClient: client)
    let result = try await probe.testConnection(
        profile: TransportFixtures.loopbackProfile(),
        secretProvider: { _ in nil }
    )
    #expect(result.succeeded)
    #expect(result.message.contains("completion probe"))
    #expect(client.requests.count == 2)
}

@Test
func connectionProbeCompletionFallbackHonorsRetryAfterDelay() async throws {
    let client = ScriptedTransportHTTPClient(outcomes: [
        .response(status: 404, data: Data(), headers: [:]),
        .response(
            status: 429,
            data: Data(#"{"error":{"code":"rate_limit_exceeded","message":"Slow"}}"#.utf8),
            headers: ["Retry-After": "7"]
        ),
        .response(
            status: 200,
            data: TransportFixtures.chatCompletionsSuccess(text: "OK"),
            headers: [:]
        ),
    ])
    let delays = ConnectionProbeDelayRecorder()
    let probe = OpenAICompatibleConnectionProbe(
        httpClient: client,
        retryDelay: { seconds in await delays.record(seconds) }
    )

    let result = try await probe.testConnection(
        profile: TransportFixtures.loopbackProfile(),
        secretProvider: { _ in nil }
    )

    #expect(result.succeeded)
    #expect(client.requests.count == 3)
    #expect(await delays.values == [7])
}

private actor ConnectionProbeDelayRecorder {
    private(set) var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}

@Test(arguments: [404, 405, 501])
func connectionProbeListModelsMarksUnsupportedEndpoint(status: Int) async throws {
    let client = ScriptedTransportHTTPClient(outcomes: [
        .response(status: status, data: Data(), headers: [:]),
    ])
    let probe = OpenAICompatibleConnectionProbe(httpClient: client)
    let discovery = try await probe.listModels(
        profile: TransportFixtures.openAIProfile(),
        secretProvider: { _ in "sk" }
    )
    #expect(discovery.models.isEmpty)
    #expect(discovery.modelsEndpointAvailable == false)
}

@Test
func connectionProbeRefusesInvalidProfileWithoutNetwork() async throws {
    let client = ScriptedTransportHTTPClient(outcomes: [])
    let profile = ProviderProfile(
        id: UUID(),
        name: "Bad",
        kind: .custom,
        endpoint: URL(string: "http://evil.example/v1")!,
        apiStyle: .chatCompletions,
        authentication: .none,
        models: [:]
    )
    let probe = OpenAICompatibleConnectionProbe(httpClient: client)
    await #expect(throws: MLingoError.self) {
        _ = try await probe.testConnection(profile: profile, secretProvider: { _ in nil })
    }
    #expect(client.requests.isEmpty)
}

@Test
func connectionProbeMapsTimeout() async throws {
    let client = ScriptedTransportHTTPClient(outcomes: [
        .failure(URLError(.timedOut)),
    ])
    let probe = OpenAICompatibleConnectionProbe(httpClient: client)
    await #expect(throws: MLingoError.requestTimedOut) {
        _ = try await probe.listModels(
            profile: TransportFixtures.openAIProfile(),
            secretProvider: { _ in "sk" }
        )
    }
}

@Test
func diagnosticRedactorHidesSecretsAndUserText() {
    let text = "Bearer sk-secret-123 said Hello world for user Hello world"
    let redacted = ProviderDiagnosticRedactor.safeDescription(
        text,
        secrets: ["sk-secret-123"],
        userTexts: ["Hello world"]
    )
    #expect(!redacted.contains("sk-secret-123"))
    #expect(!redacted.contains("Hello world"))
    #expect(redacted.contains("[redacted]"))
    #expect(redacted.contains("[user-text]"))
    #expect(
        ProviderDiagnosticRedactor.redactAuthorizationHeader("Bearer sk-abc")
            == "Bearer [redacted]"
    )

    #expect(
        ProviderDiagnosticRedactor.safeDescription(
            "sk-abcdef sk-secret [redacted]",
            secrets: ["sk-abc", "sk-abcdef", "sk-secret"],
            userTexts: ["[redacted]"]
        ) == "[redacted] [redacted] [user-text]"
    )
    #expect(
        ProviderDiagnosticRedactor.safeDescription(
            "abcdef",
            secrets: ["abc"],
            userTexts: ["bcdef"]
        ) == "[redacted]"
    )
}

@Test
func diagnosticRedactorSanitizesServerControlledRequestIDs() {
    #expect(
        ProviderDiagnosticRedactor.sanitizeServerControlledHeader("req_abc-123")
            == "[redacted]"
    )
    #expect(
        ProviderDiagnosticRedactor.sanitizeServerControlledHeader("sk-leaked")
            == "[redacted]"
    )
    // Free-form / secret-bearing values are rejected wholesale — never filtered remnants.
    #expect(
        ProviderDiagnosticRedactor.sanitizeServerControlledHeader(
            "evil\nAuthorization: Bearer sk-leaked"
        ) == "unavailable"
    )
    #expect(
        ProviderDiagnosticRedactor.sanitizeServerControlledHeader("Bearer sk-leaked")
            == "unavailable"
    )
    #expect(
        !ProviderDiagnosticRedactor.sanitizeServerControlledHeader(
            "evil Authorization: Bearer sk-leaked"
        ).contains("sk-leaked")
    )
    #expect(ProviderDiagnosticRedactor.sanitizeServerControlledHeader(nil) == "unavailable")
    #expect(ProviderDiagnosticRedactor.sanitizeServerControlledHeader("!!!") == "unavailable")
    #expect(
        ProviderDiagnosticRedactor.sanitizeServerControlledHeader(String(repeating: "a", count: 80))
            == "unavailable"
    )
}
