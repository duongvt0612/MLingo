import Foundation
import Testing
@testable import MLingoCore

/// Opt-in live suites. Default `swift test` never hits the network.
///
/// All live tests require:
/// - `MLINGO_RUN_LIVE_PROVIDER_TESTS=1`
///
/// Plus one of:
/// - `OPENAI_API_KEY` — live OpenAI Responses translation
/// - `MLINGO_OLLAMA_BASE_URL` (+ optional `MLINGO_OLLAMA_MODEL`) — loopback Ollama
/// - `MLINGO_LMSTUDIO_BASE_URL` (+ optional `MLINGO_LMSTUDIO_MODEL`) — loopback LM Studio

private enum LiveProviderTestGate {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MLINGO_RUN_LIVE_PROVIDER_TESTS"] == "1"
    }
}

@Test
func liveOpenAICompatibleResponsesWhenExplicitlyEnabled() async throws {
    guard LiveProviderTestGate.isEnabled else { return }
    guard
        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !apiKey.isEmpty
    else {
        return
    }

    let profile = OpenAICompatiblePresets.make(
        kind: .openAI,
        models: [.translation: ["gpt-4o-mini"]]
    )
    let engine = OpenAITranslationEngine(
        profile: profile,
        secretProvider: { _ in apiKey }
    )
    let input = "Let's deploy this service with Docker and PostgreSQL."
    let subtitle = try await engine.translate(
        TranslationRequest(
            current: Transcript(
                text: input,
                timestamp: 0
            )
        ),
        settings: AppSettings(
            openAIModel: "gpt-4o-mini",
            sourceLanguage: "English",
            targetLanguage: "Vietnamese"
        )
    )
    #expect(!subtitle.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(subtitle.translated.normalizedForTranslationAssertion != input.normalizedForTranslationAssertion)
}

@Test
func liveOllamaChatCompletionsWhenExplicitlyEnabled() async throws {
    guard LiveProviderTestGate.isEnabled else { return }
    guard
        let base = ProcessInfo.processInfo.environment["MLINGO_OLLAMA_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !base.isEmpty,
        let endpoint = URL(string: base)
    else {
        return
    }
    let model = ProcessInfo.processInfo.environment["MLINGO_OLLAMA_MODEL"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty ?? "llama3.2"
    let profile = ProviderProfile(
        id: UUID(),
        name: "Ollama Live",
        kind: .ollama,
        endpoint: endpoint,
        apiStyle: .chatCompletions,
        authentication: .none,
        models: [.translation: [model]]
    )
    let engine = OpenAITranslationEngine(
        profile: profile,
        secretProvider: { _ in nil }
    )
    let input = "Hello world"
    let subtitle = try await engine.translate(
        TranslationRequest(current: Transcript(text: input, timestamp: 0)),
        settings: AppSettings(
            openAIModel: model,
            sourceLanguage: "English",
            targetLanguage: "Vietnamese"
        )
    )
    #expect(!subtitle.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(subtitle.translated.normalizedForTranslationAssertion != input.normalizedForTranslationAssertion)
}

@Test
func liveLMStudioChatCompletionsWhenExplicitlyEnabled() async throws {
    guard LiveProviderTestGate.isEnabled else { return }
    guard
        let base = ProcessInfo.processInfo.environment["MLINGO_LMSTUDIO_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !base.isEmpty,
        let endpoint = URL(string: base)
    else {
        return
    }
    let model = ProcessInfo.processInfo.environment["MLINGO_LMSTUDIO_MODEL"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty ?? "local-model"
    let profile = ProviderProfile(
        id: UUID(),
        name: "LM Studio Live",
        kind: .lmStudio,
        endpoint: endpoint,
        apiStyle: .chatCompletions,
        authentication: .none,
        models: [.translation: [model]]
    )
    let engine = OpenAITranslationEngine(
        profile: profile,
        secretProvider: { _ in nil }
    )
    let input = "Hello world"
    let subtitle = try await engine.translate(
        TranslationRequest(current: Transcript(text: input, timestamp: 0)),
        settings: AppSettings(
            openAIModel: model,
            sourceLanguage: "English",
            targetLanguage: "Vietnamese"
        )
    )
    #expect(!subtitle.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(subtitle.translated.normalizedForTranslationAssertion != input.normalizedForTranslationAssertion)
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    var normalizedForTranslationAssertion: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
