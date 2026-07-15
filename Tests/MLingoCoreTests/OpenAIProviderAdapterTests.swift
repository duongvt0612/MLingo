import Foundation
import Testing
@testable import MLingoCore

@Test
func openAIProviderAdapterPreservesRequestLanguagesModelAndResult() async throws {
    let engine = RecordingLegacyTranslationEngine()
    let adapter = OpenAITranslationProviderAdapter(engine: engine)
    let request = TranslationProviderRequest(
        translation: TranslationRequest(
            current: Transcript(text: "hello", timestamp: 4),
            context: [Transcript(text: "previous", timestamp: 1)]
        ),
        model: "gpt-provider",
        sourceLanguage: "English",
        targetLanguage: "Vietnamese"
    )

    let result = try await adapter.translate(request)

    #expect(result.translated == "translated")
    #expect(await engine.lastRequest == request.translation)
    #expect(await engine.lastSettings?.openAIModel == "gpt-provider")
    #expect(await engine.lastSettings?.sourceLanguage == "English")
    #expect(await engine.lastSettings?.targetLanguage == "Vietnamese")
}

@Test
func providerTranslationEngineUsesOnlyTheRegistryTranslationSelection() async throws {
    let selectedID = UUID()
    let ignoredID = UUID()
    let selected = ProviderProfile(
        id: selectedID,
        name: "Selected",
        kind: .openAI,
        endpoint: URL(string: "https://api.openai.com/v1")!,
        apiStyle: .responses,
        authentication: .none,
        models: [.translation: ["selected-model"]]
    )
    let ignored = ProviderProfile(
        id: ignoredID,
        name: "Ignored",
        kind: .custom,
        endpoint: URL(string: "https://ignored.example/v1")!,
        apiStyle: .responses,
        authentication: .none,
        models: [.translation: ["ignored-model"]]
    )
    let store = AdapterProfileStore(configuration: ProviderConfiguration(
        profiles: [ignored, selected],
        selections: [
            .translation: CapabilitySelection(
                profileID: selectedID,
                model: "selected-model"
            ),
        ]
    ))
    let provider = RecordingTranslationProvider()
    let resolver = ResolvedSelectionRecorder(provider: provider)
    let engine = ProviderTranslationEngine(
        profileStore: store,
        providerResolver: { selection in resolver.resolve(selection) }
    )

    _ = try await engine.translate(
        TranslationRequest(current: Transcript(text: "hello", timestamp: 0)),
        settings: AppSettings(
            openAIModel: "legacy-ui-model",
            sourceLanguage: "English",
            targetLanguage: "Vietnamese"
        )
    )

    #expect(resolver.latest?.profile.id == selectedID)
    #expect(await provider.latest?.model == "selected-model")
}

@Test
func legacyOpenAIMigrationMovesCredentialAndModelThenDeletesLegacyKey() async throws {
    let profileStore = AdapterProfileStore()
    let credentials = AdapterCredentialStore()
    let legacy = AdapterLegacyAPIKeyStore(key: " sk-legacy ")
    let migrator = LegacyOpenAIProviderMigrator(
        profileStore: profileStore,
        credentialStore: credentials,
        legacyAPIKeyStore: legacy
    )

    try await migrator.migrate(settings: AppSettings(openAIModel: "gpt-legacy"))

    let configuration = try await profileStore.load()
    let resolved = try ProviderRegistry(
        profiles: configuration.profiles,
        selections: configuration.selections
    ).resolve(.translation)
    #expect(resolved.profile.id == ProviderDefaults.openAIProfileID)
    #expect(resolved.model == "gpt-legacy")
    #expect(try credentials.loadCredential(for: ProviderDefaults.openAICredentialID) == "sk-legacy")
    #expect(legacy.key == nil)

    try await migrator.migrate(settings: AppSettings(openAIModel: "gpt-legacy"))
    #expect(await profileStore.saveCount == 1)
}

@Test
func legacyOpenAIMigrationRollsBackNewCredentialWhenProfileSaveFails() async {
    let profileStore = AdapterProfileStore(saveError: AdapterTestError.saveFailed)
    let credentials = AdapterCredentialStore()
    let legacy = AdapterLegacyAPIKeyStore(key: "sk-legacy")
    let migrator = LegacyOpenAIProviderMigrator(
        profileStore: profileStore,
        credentialStore: credentials,
        legacyAPIKeyStore: legacy
    )

    await #expect(throws: AdapterTestError.saveFailed) {
        try await migrator.migrate(settings: AppSettings(openAIModel: "gpt-test"))
    }
    #expect(
        (try? credentials.loadCredential(for: ProviderDefaults.openAICredentialID)) == nil
    )
    #expect(legacy.key == "sk-legacy")
}

private actor RecordingLegacyTranslationEngine: TranslationEngineProtocol {
    private(set) var lastRequest: TranslationRequest?
    private(set) var lastSettings: AppSettings?

    func translate(
        _ request: TranslationRequest,
        settings: AppSettings
    ) async throws -> SubtitleItem {
        lastRequest = request
        lastSettings = settings
        return SubtitleItem(
            original: request.current.text,
            translated: "translated",
            start: request.current.timestamp,
            end: request.current.timestamp + 3
        )
    }
}

private actor RecordingTranslationProvider: TranslationProvider {
    private(set) var latest: TranslationProviderRequest?

    func translate(_ request: TranslationProviderRequest) async throws -> SubtitleItem {
        latest = request
        return SubtitleItem(
            original: request.translation.current.text,
            translated: "translated",
            start: request.translation.current.timestamp,
            end: request.translation.current.timestamp + 3
        )
    }
}

private final class ResolvedSelectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let provider: any TranslationProvider
    private var stored: ResolvedProviderSelection?

    init(provider: any TranslationProvider) {
        self.provider = provider
    }

    var latest: ResolvedProviderSelection? { lock.withLock { stored } }

    func resolve(_ selection: ResolvedProviderSelection) -> any TranslationProvider {
        lock.withLock { stored = selection }
        return provider
    }
}

private actor AdapterProfileStore: ProviderProfileStoreProtocol {
    private var configuration: ProviderConfiguration
    private let saveError: (any Error)?
    private(set) var saveCount = 0

    init(
        configuration: ProviderConfiguration = ProviderConfiguration(),
        saveError: (any Error)? = nil
    ) {
        self.configuration = configuration
        self.saveError = saveError
    }

    func load() async throws -> ProviderConfiguration { configuration }

    func save(_ configuration: ProviderConfiguration) async throws {
        if let saveError { throw saveError }
        self.configuration = configuration
        saveCount += 1
    }
}

private final class AdapterCredentialStore: ProviderCredentialStoreProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [CredentialID: String] = [:]

    func loadCredential(for id: CredentialID) throws -> String? {
        lock.withLock { values[id] }
    }

    func saveCredential(_ secret: String, for id: CredentialID) throws {
        lock.withLock { values[id] = secret }
    }

    func deleteCredential(for id: CredentialID) throws {
        lock.withLock { _ = values.removeValue(forKey: id) }
    }
}

private final class AdapterLegacyAPIKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: String?

    init(key: String?) { storedKey = key }

    var key: String? { lock.withLock { storedKey } }

    func loadAPIKey() throws -> String? { lock.withLock { storedKey } }
    func saveAPIKey(_ apiKey: String) throws { lock.withLock { storedKey = apiKey } }
    func deleteAPIKey() throws { lock.withLock { storedKey = nil } }
}

private enum AdapterTestError: Error {
    case saveFailed
}
