import Foundation
import Testing
@testable import MLingoCore

@Test
func openAITranslatesLiveFixtureWhenAPIKeyIsAvailable() async throws {
    guard
        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !apiKey.isEmpty
    else {
        return
    }

    let engine = OpenAITranslationEngine(
        apiKeyStore: LiveAPIKeyStore(apiKey: apiKey)
    )
    let fixture = "Let's deploy this service with Docker and PostgreSQL."
    let start = ContinuousClock.now
    let subtitle = try await engine.translate(
        TranslationRequest(current: Transcript(text: fixture, timestamp: 0)),
        settings: AppSettings()
    )
    let latency = start.duration(to: .now)

    #expect(!subtitle.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(subtitle.translated.contains("Docker"))
    #expect(subtitle.translated.contains("PostgreSQL"))
    print("OpenAI live translation latency: \(latency)")
}

private final class LiveAPIKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    private var apiKey: String?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func loadAPIKey() throws -> String? { apiKey }
    func saveAPIKey(_ apiKey: String) throws { self.apiKey = apiKey }
    func deleteAPIKey() throws { apiKey = nil }
}
