import Foundation
import Testing
@testable import MLingoCore

@Test
func registryResolvesTheExplicitProfileAndModelForEachCapability() throws {
    let profileID = UUID()
    let profile = ProviderProfile(
        id: profileID,
        name: "OpenAI",
        kind: .openAI,
        endpoint: URL(string: "https://api.openai.com/v1")!,
        apiStyle: .responses,
        authentication: .bearer(credentialID: CredentialID("openai-main")),
        models: [.translation: ["gpt-5.4-mini"], .chat: ["gpt-5.4"]]
    )
    let registry = ProviderRegistry(
        profiles: [profile],
        selections: [
            .translation: CapabilitySelection(
                profileID: profileID,
                model: "gpt-5.4-mini"
            ),
        ]
    )

    let resolved = try registry.resolve(.translation)

    #expect(resolved.profile == profile)
    #expect(resolved.model == "gpt-5.4-mini")
    #expect(resolved.capability == .translation)
}

@Test
func registryNeverFallsBackWhenTheSelectedProfileIsMissing() {
    let available = ProviderProfile(
        name: "Available local server",
        kind: .ollama,
        endpoint: URL(string: "http://localhost:11434/v1")!,
        apiStyle: .chatCompletions,
        authentication: .none,
        models: [.translation: ["qwen3:4b"]]
    )
    let missingID = UUID()
    let registry = ProviderRegistry(
        profiles: [available],
        selections: [
            .translation: CapabilitySelection(
                profileID: missingID,
                model: "qwen3:4b"
            ),
        ]
    )

    #expect(throws: ProviderResolutionError(
        issue: .profileNotFound(missingID),
        recoveryAction: .selectProvider(.translation)
    )) {
        try registry.resolve(.translation)
    }
}

@Test
func registryReturnsTypedRecoveryForMissingSelectionAndModel() {
    let profile = ProviderProfile(
        name: "OpenAI",
        kind: .openAI,
        endpoint: URL(string: "https://api.openai.com/v1")!,
        apiStyle: .responses,
        authentication: .none,
        models: [.translation: ["gpt-test"]]
    )

    #expect(throws: ProviderResolutionError(
        issue: .selectionMissing(.translation),
        recoveryAction: .selectProvider(.translation)
    )) {
        try ProviderRegistry(profiles: [profile], selections: [:]).resolve(.translation)
    }

    let selection = CapabilitySelection(profileID: profile.id, model: "missing")
    #expect(throws: ProviderResolutionError(
        issue: .modelUnavailable(profile.id, .translation, "missing"),
        recoveryAction: .selectModel(.translation)
    )) {
        try ProviderRegistry(
            profiles: [profile],
            selections: [.translation: selection]
        ).resolve(.translation)
    }
}

@Test(arguments: [
    "http://localhost:11434/v1",
    "http://127.0.0.1:1234/v1",
    "http://[::1]:1234/v1",
    "https://ai.example.com/v1",
])
func profileValidationAllowsHTTPSAndLoopbackHTTP(endpoint: String) {
    let profile = ProviderProfile(
        name: "Allowed endpoint",
        kind: .custom,
        endpoint: URL(string: endpoint)!,
        apiStyle: .responses,
        authentication: .none,
        models: [.translation: ["model"]]
    )

    #expect(profile.validationIssues.isEmpty)
}

@Test
func profileValidationRejectsRemoteHTTPAndUnsafeCustomHeaders() {
    let profile = ProviderProfile(
        name: "Unsafe endpoint",
        kind: .custom,
        endpoint: URL(string: "http://ai.example.com/v1")!,
        apiStyle: .responses,
        authentication: .customHeader(
            name: "Bad Header:\nInjected",
            credentialID: CredentialID("custom-secret")
        ),
        models: [.translation: ["model"]]
    )

    #expect(profile.validationIssues == [
        .remoteEndpointRequiresHTTPS,
        .invalidCustomHeaderName,
    ])
}

@Test
func profileValidationRejectsEmbeddedCredentialsAndQueryFragments() {
    let withUserInfo = ProviderProfile(
        name: "Secret in URL",
        kind: .custom,
        endpoint: URL(string: "https://user:secret@example.com/v1")!,
        apiStyle: .chatCompletions,
        authentication: .none,
        models: [.translation: ["m"]]
    )
    #expect(withUserInfo.validationIssues.contains(.endpointContainsCredentials))

    let withQuery = ProviderProfile(
        name: "Query key",
        kind: .custom,
        endpoint: URL(string: "https://example.com/v1?api-key=sk-leaked")!,
        apiStyle: .chatCompletions,
        authentication: .none,
        models: [.translation: ["m"]]
    )
    #expect(withQuery.validationIssues.contains(.endpointContainsQueryOrFragment))

    let withFragment = ProviderProfile(
        name: "Fragment",
        kind: .custom,
        endpoint: URL(string: "https://example.com/v1#token")!,
        apiStyle: .chatCompletions,
        authentication: .none,
        models: [.translation: ["m"]]
    )
    #expect(withFragment.validationIssues.contains(.endpointContainsQueryOrFragment))
}

@Test
func profileValidationRejectsHTTPSEndpointWithoutHost() {
    let profile = ProviderProfile(
        name: "Missing host",
        kind: .custom,
        endpoint: URL(string: "https:/v1")!,
        apiStyle: .responses,
        authentication: .none,
        models: [.translation: ["model"]]
    )

    #expect(profile.validationIssues == [.missingEndpointHost])
}

@Test
func encodedProfileReferencesCredentialWithoutContainingASecret() throws {
    let profile = ProviderProfile(
        name: "Custom",
        kind: .custom,
        endpoint: URL(string: "https://ai.example.com/v1")!,
        apiStyle: .chatCompletions,
        authentication: .customHeader(
            name: "X-API-Key",
            credentialID: CredentialID("credential-reference")
        ),
        models: [.chat: ["chat-model"]]
    )

    let data = try JSONEncoder().encode(profile)
    let encoded = String(decoding: data, as: UTF8.self)

    #expect(encoded.contains("credential-reference"))
    #expect(!encoded.contains("actual-secret-value"))
    #expect(try JSONDecoder().decode(ProviderProfile.self, from: data) == profile)
}
