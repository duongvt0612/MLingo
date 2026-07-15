import Foundation
import Testing
@testable import MLingoCore

@Test
func openAIPresetUsesHTTPSResponsesAndBearer() {
    let profile = OpenAICompatiblePresets.make(kind: .openAI, models: [
        .translation: ["gpt-4o-mini"],
    ])
    #expect(profile.kind == .openAI)
    #expect(profile.name == "OpenAI")
    #expect(profile.endpoint == OpenAICompatiblePresets.openAIEndpoint)
    #expect(profile.apiStyle == .responses)
    #expect(profile.authentication == .bearer(credentialID: ProviderDefaults.openAICredentialID))
    #expect(profile.validationIssues.isEmpty)
}

@Test
func ollamaPresetUsesLoopbackChatCompletionsWithoutAuth() {
    let profile = OpenAICompatiblePresets.make(kind: .ollama)
    #expect(profile.kind == .ollama)
    #expect(profile.endpoint == OpenAICompatiblePresets.ollamaEndpoint)
    #expect(profile.apiStyle == .chatCompletions)
    #expect(profile.authentication == .none)
    #expect(profile.validationIssues.isEmpty)
}

@Test
func lmStudioPresetUsesLoopbackChatCompletionsWithoutAuth() {
    let profile = OpenAICompatiblePresets.make(kind: .lmStudio)
    #expect(profile.kind == .lmStudio)
    #expect(profile.endpoint == OpenAICompatiblePresets.lmStudioEndpoint)
    #expect(profile.apiStyle == .chatCompletions)
    #expect(profile.authentication == .none)
    #expect(profile.validationIssues.isEmpty)
}

@Test
func customPresetDoesNotInventEndpointOrSecrets() {
    let profile = OpenAICompatiblePresets.make(kind: .custom, name: "My Server")
    #expect(profile.kind == .custom)
    #expect(profile.name == "My Server")
    #expect(profile.endpoint == nil)
    #expect(profile.authentication == .none)
    #expect(profile.validationIssues.contains(.missingEndpoint))
}

@Test
func remoteHTTPIsRejectedWhileLoopbackHTTPIsAllowed() {
    let remote = ProviderProfile(
        id: UUID(),
        name: "Remote HTTP",
        kind: .custom,
        endpoint: URL(string: "http://api.example.com/v1")!,
        apiStyle: .chatCompletions,
        authentication: .none,
        models: [:]
    )
    #expect(remote.validationIssues.contains(.remoteEndpointRequiresHTTPS))

    let loopback = OpenAICompatiblePresets.make(kind: .ollama)
    #expect(!loopback.validationIssues.contains(.remoteEndpointRequiresHTTPS))
}
