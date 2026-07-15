import Foundation

public enum OpenAICompatiblePresets {
    public static let openAIEndpoint = URL(string: "https://api.openai.com/v1")!
    public static let ollamaEndpoint = URL(string: "http://127.0.0.1:11434/v1")!
    public static let lmStudioEndpoint = URL(string: "http://127.0.0.1:1234/v1")!

    public static func make(
        kind: ProviderKind,
        name: String? = nil,
        id: UUID = UUID(),
        models: [ModelCapability: [String]] = [:]
    ) -> ProviderProfile {
        switch kind {
        case .openAI:
            return ProviderProfile(
                id: id,
                name: name ?? "OpenAI",
                kind: .openAI,
                endpoint: openAIEndpoint,
                apiStyle: .responses,
                authentication: .bearer(credentialID: ProviderDefaults.openAICredentialID),
                models: models
            )
        case .ollama:
            return ProviderProfile(
                id: id,
                name: name ?? "Ollama",
                kind: .ollama,
                endpoint: ollamaEndpoint,
                apiStyle: .chatCompletions,
                authentication: .none,
                models: models
            )
        case .lmStudio:
            return ProviderProfile(
                id: id,
                name: name ?? "LM Studio",
                kind: .lmStudio,
                endpoint: lmStudioEndpoint,
                apiStyle: .chatCompletions,
                authentication: .none,
                models: models
            )
        case .custom:
            return ProviderProfile(
                id: id,
                name: name ?? "Custom",
                kind: .custom,
                endpoint: nil,
                apiStyle: .chatCompletions,
                authentication: .none,
                models: models
            )
        case .builtInMLX, .system:
            return ProviderProfile(
                id: id,
                name: name ?? kind.rawValue,
                kind: kind,
                endpoint: nil,
                apiStyle: .native,
                authentication: .none,
                models: models
            )
        }
    }
}
