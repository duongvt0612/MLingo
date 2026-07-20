import Foundation

public enum ProviderDefaults {
    public static let openAIProfileID = UUID(
        uuidString: "4D4C494E-474F-4000-8000-000000000001"
    )!
    public static let openAICredentialID = CredentialID("openai-default")
}

public final class OpenAITranslationProviderAdapter: TranslationProvider,
    @unchecked Sendable
{
    private let engine: any TranslationEngineProtocol

    public init(engine: any TranslationEngineProtocol) {
        self.engine = engine
    }

    public func translate(
        _ request: TranslationProviderRequest
    ) async throws -> SubtitleItem {
        let settings = AppSettings(
            openAIModel: request.model,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage
        )
        return try await engine.translate(request.translation, settings: settings)
    }
}

/// Builds a profile-aware OpenAI-compatible translation provider from a registry selection.
public enum OpenAICompatibleTranslationProviderFactory {
    public static func make(
        selection: ResolvedProviderSelection,
        credentialStore: any ProviderCredentialStoreProtocol,
        httpClient: HTTPClientProtocol = URLSession.shared
    ) throws -> any TranslationProvider {
        guard selection.profile.kind.requiresEndpoint,
              selection.profile.apiStyle == .responses
            || selection.profile.apiStyle == .chatCompletions
        else {
            throw MLingoError.invalidTranslationConfiguration(
                "Native provider selections require a native translation provider."
            )
        }
        let engine = OpenAITranslationEngine(
            profile: selection.profile,
            secretProvider: { id in try credentialStore.loadCredential(for: id) },
            httpClient: httpClient
        )
        return OpenAITranslationProviderAdapter(engine: engine)
    }
}

public final class ProviderTranslationEngine: TranslationEngineProtocol,
    @unchecked Sendable
{
    public typealias ProviderResolver = @Sendable (
        ResolvedProviderSelection
    ) throws -> any TranslationProvider

    private let profileStore: any ProviderProfileStoreProtocol
    private let providerResolver: ProviderResolver

    public init(
        profileStore: any ProviderProfileStoreProtocol,
        providerResolver: @escaping ProviderResolver
    ) {
        self.profileStore = profileStore
        self.providerResolver = providerResolver
    }

    public func translate(
        _ request: TranslationRequest,
        settings: AppSettings
    ) async throws -> SubtitleItem {
        try await translate(request, settings: settings, selection: nil)
    }

    public func translate(
        _ request: TranslationRequest,
        settings: AppSettings,
        selection: ResolvedProviderSelection?
    ) async throws -> SubtitleItem {
        let resolvedSelection: ResolvedProviderSelection
        if let selection {
            resolvedSelection = selection
        } else {
            let configuration = try await profileStore.load()
            resolvedSelection = try ProviderRegistry(
                profiles: configuration.profiles,
                selections: configuration.selections
            ).resolve(.translation)
        }
        let provider = try providerResolver(resolvedSelection)
        return try await provider.translate(
            TranslationProviderRequest(
                translation: request,
                model: resolvedSelection.model,
                sourceLanguage: settings.sourceLanguage,
                targetLanguage: settings.targetLanguage
            )
        )
    }
}

public final class ProviderAPIKeyStoreAdapter: APIKeyStoreProtocol, @unchecked Sendable {
    private let credentialStore: any ProviderCredentialStoreProtocol
    private let credentialID: CredentialID

    public init(
        credentialStore: any ProviderCredentialStoreProtocol,
        credentialID: CredentialID = ProviderDefaults.openAICredentialID
    ) {
        self.credentialStore = credentialStore
        self.credentialID = credentialID
    }

    public func loadAPIKey() throws -> String? {
        try credentialStore.loadCredential(for: credentialID)
    }

    public func saveAPIKey(_ apiKey: String) throws {
        try credentialStore.saveCredential(apiKey, for: credentialID)
    }

    public func deleteAPIKey() throws {
        try credentialStore.deleteCredential(for: credentialID)
    }
}

public protocol ProviderMigrationProtocol: Sendable {
    func migrate(settings: AppSettings) async throws
}

public actor LegacyOpenAIProviderMigrator: ProviderMigrationProtocol {
    private let profileStore: any ProviderProfileStoreProtocol
    private let credentialStore: any ProviderCredentialStoreProtocol
    private let legacyAPIKeyStore: any APIKeyStoreProtocol

    public init(
        profileStore: any ProviderProfileStoreProtocol,
        credentialStore: any ProviderCredentialStoreProtocol,
        legacyAPIKeyStore: any APIKeyStoreProtocol
    ) {
        self.profileStore = profileStore
        self.credentialStore = credentialStore
        self.legacyAPIKeyStore = legacyAPIKeyStore
    }

    public func migrate(settings: AppSettings) async throws {
        var configuration = try await profileStore.load()
        let model = settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyKey = try legacyAPIKeyStore.loadAPIKey()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usableLegacyKey = legacyKey.flatMap { $0.isEmpty ? nil : $0 }
        let existingCredential = try credentialStore.loadCredential(
            for: ProviderDefaults.openAICredentialID
        )
        let shouldCopyCredential = existingCredential == nil && usableLegacyKey != nil

        let changed = reconcileProfile(model: model, configuration: &configuration)
        if shouldCopyCredential, let usableLegacyKey {
            try credentialStore.saveCredential(
                usableLegacyKey,
                for: ProviderDefaults.openAICredentialID
            )
        }

        do {
            if changed {
                try await profileStore.save(configuration)
            }
        } catch {
            if shouldCopyCredential {
                try? credentialStore.deleteCredential(for: ProviderDefaults.openAICredentialID)
            }
            throw error
        }

        if usableLegacyKey != nil {
            try legacyAPIKeyStore.deleteAPIKey()
        }
    }

    private func reconcileProfile(
        model: String,
        configuration: inout ProviderConfiguration
    ) -> Bool {
        guard !model.isEmpty else { return false }
        let openAISelection = CapabilitySelection(
            profileID: ProviderDefaults.openAIProfileID,
            model: model
        )
        // Never hijack an explicit non-OpenAI capability selection (e.g. Ollama / LM Studio).
        let currentSelection = configuration.selections[.translation]
        let ownsTranslationSelection = currentSelection == nil
            || currentSelection?.profileID == ProviderDefaults.openAIProfileID

        if configuration.profiles.contains(
            where: { $0.id == ProviderDefaults.openAIProfileID }
        ) {
            // ProviderConfiguration is canonical after the one-time migration. Re-running
            // migration during app load/start must never overwrite user-edited models or
            // capability assignments with the legacy AppSettings.openAIModel value.
            return false
        }

        configuration.profiles.append(
            ProviderProfile(
                id: ProviderDefaults.openAIProfileID,
                name: "OpenAI",
                kind: .openAI,
                endpoint: URL(string: "https://api.openai.com/v1")!,
                apiStyle: .responses,
                authentication: .bearer(
                    credentialID: ProviderDefaults.openAICredentialID
                ),
                models: [.translation: [model]]
            )
        )
        if ownsTranslationSelection {
            configuration.selections[.translation] = openAISelection
        }
        return true
    }
}
