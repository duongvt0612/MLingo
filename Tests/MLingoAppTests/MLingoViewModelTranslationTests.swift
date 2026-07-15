import Foundation
import MLingoCore
import SwiftUI
import Testing
@testable import MLingoApp

@Test @MainActor
func openAISettingsValidationReportsEachRequiredDraftField() {
    let validation = OpenAISettingsValidation(
        apiKey: "  ",
        settings: AppSettings(
            openAIModel: " ",
            sourceLanguage: "",
            targetLanguage: "  "
        )
    )

    #expect(validation.apiKeyError != nil)
    #expect(validation.modelError != nil)
    #expect(validation.sourceLanguageError != nil)
    #expect(validation.targetLanguageError != nil)
    #expect(!validation.isValid)
}

@Test @MainActor
func openAISettingsValidationIgnoresUnrelatedSettingsErrors() {
    var settings = AppSettings()
    settings.whisperModel = ""
    settings.subtitleFontName = ""
    settings.subtitleFontSize = 1
    settings.subtitleBackgroundOpacity = 0
    settings.subtitleTextOpacity = 2

    let validation = OpenAISettingsValidation(apiKey: "sk-test", settings: settings)

    #expect(validation.isValid)
    #expect(validation.hasValidTranslationSettings)
    #expect(validation.firstError == nil)
}

@Test @MainActor
func translationTestUsesDraftValuesWithoutPersistingThem() async throws {
    let settingsStore = AppTestSettingsStore()
    let keyStore = AppTestAPIKeyStore()
    let testEngine = AppTestTranslationEngine()
    let keyRecorder = AppTestKeyRecorder()
    let viewModel = makeViewModel(
        settingsStore: settingsStore,
        keyStore: keyStore,
        translationTestEngineFactory: { key in
            keyRecorder.record(key)
            return testEngine
        }
    )
    let draft = AppSettings(
        openAIModel: "gpt-draft",
        sourceLanguage: "English",
        targetLanguage: "Vietnamese"
    )

    await viewModel.testTranslation(apiKey: "  sk-draft  ", settings: draft)

    guard case .success(let result) = viewModel.translationTestState else {
        Issue.record("Expected a successful translation test")
        return
    }
    #expect(keyRecorder.latest == "sk-draft")
    #expect(await testEngine.latestRequest?.current.text == MLingoViewModel.translationTestFixture)
    #expect(result.translated.contains("Docker"))
    #expect(result.translated.contains("PostgreSQL"))
    #expect(result.model == "gpt-draft")
    #expect(result.latency >= 0)
    #expect(await settingsStore.saveCount == 0)
    #expect(keyStore.saveCount == 0)
}

@Test @MainActor
func translationTestSurfacesValidationWithoutCallingEngine() async {
    let testEngine = AppTestTranslationEngine()
    let viewModel = makeViewModel(
        translationTestEngineFactory: { _ in testEngine }
    )

    await viewModel.testTranslation(
        apiKey: "",
        settings: AppSettings(openAIModel: "")
    )

    guard case .failure(let message) = viewModel.translationTestState else {
        Issue.record("Expected validation failure")
        return
    }
    #expect(message.contains("API key"))
    #expect(await testEngine.callCount == 0)
}

@Test @MainActor
func startPipelineStopsWhenSavingSettingsFails() async throws {
    let settingsStore = AppTestSettingsStore(saveError: AppTestError.saveFailed)
    let audioFactory = AppTestAudioFactory()
    let viewModel = makeViewModel(
        settingsStore: settingsStore,
        audioFactory: audioFactory,
        translationTestEngineFactory: { _ in AppTestTranslationEngine() }
    )

    viewModel.startTranscriptionTest()

    try await appEventually {
        viewModel.lastError != nil && viewModel.activeMode == .idle
    }
    #expect(audioFactory.makeCount == 0)
    #expect(viewModel.status != "Starting transcription test")
}

@Test @MainActor
func preferencesStillLoadWhenCredentialLookupFails() async {
    let loadedSettings = AppSettings(openAIModel: "gpt-loaded")
    let settingsStore = AppTestSettingsStore(settings: loadedSettings)
    let keyStore = AppTestAPIKeyStore(loadError: AppTestError.credentialFailed)
    let viewModel = makeViewModel(settingsStore: settingsStore, keyStore: keyStore) { _ in
        AppTestTranslationEngine()
    }

    await viewModel.load()

    #expect(viewModel.settings == loadedSettings)
    #expect(viewModel.apiKey.isEmpty)
    guard case .failed = viewModel.credentialState else {
        Issue.record("Expected a failed credential state")
        return
    }
}

@Test @MainActor
func credentialStillLoadsWhenPreferencesFail() async {
    let settingsStore = AppTestSettingsStore(loadError: AppTestError.loadFailed)
    let keyStore = AppTestAPIKeyStore(storedKey: "sk-loaded")
    let viewModel = makeViewModel(settingsStore: settingsStore, keyStore: keyStore) { _ in
        AppTestTranslationEngine()
    }

    await viewModel.load()

    #expect(viewModel.apiKey == "sk-loaded")
    #expect(viewModel.credentialState == .stored)
    #expect(viewModel.lastError != nil)
}

@Test @MainActor
func loadCombinesPreferencesAndCredentialErrors() async {
    let settingsError = MLingoError.invalidSettings("Preferences could not be loaded.")
    let credentialError = MLingoError.credentialStoreFailure(
        operation: .load,
        status: -50
    )
    let viewModel = makeViewModel(
        settingsStore: AppTestSettingsStore(loadError: settingsError),
        keyStore: AppTestAPIKeyStore(loadError: credentialError)
    ) { _ in AppTestTranslationEngine() }

    await viewModel.load()

    #expect(
        viewModel.lastError
            == "\(settingsError.localizedDescription)\n\(credentialError.localizedDescription)"
    )
    #expect(viewModel.credentialState == .failed(credentialError.localizedDescription))
}

@Test @MainActor
func successfulLoadClearsAStaleErrorAfterBothStoresSucceed() async {
    let viewModel = makeViewModel { _ in AppTestTranslationEngine() }
    viewModel.lastError = "Stale error"

    await viewModel.load()

    #expect(viewModel.lastError == nil)
}

@Test @MainActor
func loadMigratesLegacyProviderConfigurationBeforeReadingCredential() async {
    let keyStore = AppTestAPIKeyStore()
    let migration = AppTestProviderMigration {
        try keyStore.saveAPIKey("sk-migrated")
    }
    let viewModel = makeViewModel(
        keyStore: keyStore,
        providerMigration: migration
    ) { _ in AppTestTranslationEngine() }

    await viewModel.load()

    #expect(migration.callCount == 1)
    #expect(viewModel.apiKey == "sk-migrated")
    #expect(viewModel.credentialState == .stored)
}

@Test @MainActor
func savingAnUnchangedAPIKeyDoesNotWriteKeychain() async {
    let keyStore = AppTestAPIKeyStore(storedKey: "sk-same")
    let viewModel = makeViewModel(keyStore: keyStore) { _ in AppTestTranslationEngine() }
    await viewModel.load()

    let saved = await viewModel.save(AppSettings(), apiKey: "  sk-same  ")

    #expect(saved)
    #expect(keyStore.saveCount == 0)
    #expect(keyStore.deleteCount == 0)
    #expect(viewModel.credentialState == .stored)
}

@Test @MainActor
func savingAnEmptyAPIKeyDeletesTheStoredCredential() async {
    let keyStore = AppTestAPIKeyStore(storedKey: "sk-old")
    let viewModel = makeViewModel(keyStore: keyStore) { _ in AppTestTranslationEngine() }
    await viewModel.load()

    let saved = await viewModel.save(AppSettings(), apiKey: "   ")

    #expect(saved)
    #expect(keyStore.deleteCount == 1)
    #expect(keyStore.currentKey == nil)
    #expect(viewModel.apiKey.isEmpty)
    #expect(viewModel.credentialState == .notStored)
}

@Test @MainActor
func credentialWriteFailurePreservesPreviousCredentialState() async {
    let keyStore = AppTestAPIKeyStore(
        storedKey: "sk-old",
        saveFailureCallNumbers: [1]
    )
    let viewModel = makeViewModel(keyStore: keyStore) { _ in AppTestTranslationEngine() }
    await viewModel.load()

    let saved = await viewModel.save(AppSettings(), apiKey: "sk-new")

    #expect(!saved)
    #expect(viewModel.apiKey == "sk-old")
    #expect(viewModel.credentialState == .stored)
    #expect(viewModel.lastError != nil)
}

@Test @MainActor
func preferencesFailureRollsBackChangedCredentialAndPreservesMemory() async {
    let originalSettings = AppSettings(openAIModel: "gpt-original")
    let settingsStore = AppTestSettingsStore(
        settings: originalSettings,
        saveError: AppTestError.saveFailed
    )
    let keyStore = AppTestAPIKeyStore(storedKey: "sk-old")
    let viewModel = makeViewModel(settingsStore: settingsStore, keyStore: keyStore) { _ in
        AppTestTranslationEngine()
    }
    await viewModel.load()

    let saved = await viewModel.save(
        AppSettings(openAIModel: "gpt-new"),
        apiKey: "sk-new"
    )

    #expect(!saved)
    #expect(keyStore.savedValues == ["sk-new", "sk-old"])
    #expect(keyStore.currentKey == "sk-old")
    #expect(viewModel.settings == originalSettings)
    #expect(viewModel.apiKey == "sk-old")
    #expect(viewModel.credentialState == .stored)
}

@Test @MainActor
func rollbackFailureLeavesInMemorySettingsUnchangedAndReportsCredentialFailure() async {
    let originalSettings = AppSettings(openAIModel: "gpt-original")
    let settingsStore = AppTestSettingsStore(
        settings: originalSettings,
        saveError: AppTestError.saveFailed
    )
    let keyStore = AppTestAPIKeyStore(
        storedKey: "sk-old",
        saveFailureCallNumbers: [2]
    )
    let viewModel = makeViewModel(settingsStore: settingsStore, keyStore: keyStore) { _ in
        AppTestTranslationEngine()
    }
    await viewModel.load()

    let saved = await viewModel.save(
        AppSettings(openAIModel: "gpt-new"),
        apiKey: "sk-new"
    )

    #expect(!saved)
    #expect(keyStore.currentKey == "sk-new")
    #expect(viewModel.settings == originalSettings)
    #expect(viewModel.apiKey == "sk-old")
    guard case .failed = viewModel.credentialState else {
        Issue.record("Expected rollback failure to be visible")
        return
    }
}

@Test @MainActor
func translationStartWithoutAPIKeyStaysIdleAndDoesNotCreateAudio() {
    let audioFactory = AppTestAudioFactory()
    let viewModel = makeViewModel(audioFactory: audioFactory) { _ in
        AppTestTranslationEngine()
    }

    viewModel.start()

    #expect(viewModel.activeMode == .idle)
    #expect(viewModel.lastError == MLingoError.missingAPIKey.localizedDescription)
    #expect(viewModel.errorRecoveryActions == [.openSettings])
    #expect(audioFactory.makeCount == 0)
}

@Test @MainActor
func translationStartWithNoneAuthProfileDoesNotRequireAPIKey() async throws {
    let audioFactory = AppTestAudioFactory()
    let ollamaID = UUID()
    let ollama = OpenAICompatiblePresets.make(
        kind: .ollama,
        id: ollamaID,
        models: [.translation: ["llama3.2"]]
    )
    let profileStore = AppTestProfileStore(configuration: ProviderConfiguration(
        profiles: [ollama],
        selections: [
            .translation: CapabilitySelection(profileID: ollamaID, model: "llama3.2"),
        ]
    ))
    let viewModel = makeViewModel(
        audioFactory: audioFactory,
        profileStore: profileStore
    ) { _ in
        AppTestTranslationEngine()
    }
    viewModel.apiKey = ""

    viewModel.start()
    try await appEventually { viewModel.status == "Listening" }
    #expect(viewModel.activeMode == .translation)
    #expect(viewModel.lastError == nil)
    #expect(audioFactory.makeCount == 1)

    viewModel.stop()
    try await appEventually { viewModel.activeMode == .idle }
}

@Test @MainActor
func translationStartUsesSelectedProfileCredentialNotOpenAIDefault() async throws {
    let audioFactory = AppTestAudioFactory()
    let customID = UUID()
    let customCredential = CredentialID("custom-provider-secret")
    let custom = ProviderProfile(
        id: customID,
        name: "Custom Bearer",
        kind: .custom,
        endpoint: URL(string: "https://api.example.com/v1")!,
        apiStyle: .chatCompletions,
        authentication: .bearer(credentialID: customCredential),
        models: [.translation: ["custom-model"]]
    )
    let profileStore = AppTestProfileStore(configuration: ProviderConfiguration(
        profiles: [custom],
        selections: [
            .translation: CapabilitySelection(profileID: customID, model: "custom-model"),
        ]
    ))
    let credentials = AppTestCredentialStore()
    try credentials.saveCredential("sk-custom-only", for: customCredential)
    let keyStore = AppTestAPIKeyStore(storedKey: nil) // OpenAI default empty
    let viewModel = makeViewModel(
        keyStore: keyStore,
        audioFactory: audioFactory,
        profileStore: profileStore,
        credentialStore: credentials
    ) { _ in AppTestTranslationEngine() }
    viewModel.apiKey = ""

    viewModel.start()
    try await appEventually { viewModel.status == "Listening" }
    #expect(viewModel.activeMode == .translation)
    #expect(viewModel.lastError == nil)
    #expect(audioFactory.makeCount == 1)

    viewModel.stop()
    try await appEventually { viewModel.activeMode == .idle }
}

@Test @MainActor
func translationSessionKeepsPreflightProviderSelectionWhenConfigurationChanges() async throws {
    let firstID = UUID()
    let secondID = UUID()
    let first = ProviderProfile(
        id: firstID,
        name: "First provider",
        kind: .custom,
        endpoint: URL(string: "https://first.example/v1")!,
        apiStyle: .chatCompletions,
        authentication: .none,
        models: [.translation: ["first-model"]]
    )
    let second = ProviderProfile(
        id: secondID,
        name: "Second provider",
        kind: .custom,
        endpoint: URL(string: "https://second.example/v1")!,
        apiStyle: .chatCompletions,
        authentication: .none,
        models: [.translation: ["second-model"]]
    )
    let firstConfiguration = ProviderConfiguration(
        profiles: [first],
        selections: [
            .translation: CapabilitySelection(profileID: firstID, model: "first-model"),
        ]
    )
    let secondConfiguration = ProviderConfiguration(
        profiles: [second],
        selections: [
            .translation: CapabilitySelection(profileID: secondID, model: "second-model"),
        ]
    )
    let profileStore = AppTestProfileStore(
        configuration: firstConfiguration,
        subsequentConfiguration: secondConfiguration
    )
    let provider = AppRecordingTranslationProvider()
    let selectionRecorder = AppResolvedSelectionRecorder(provider: provider)
    let translationEngine = ProviderTranslationEngine(
        profileStore: profileStore,
        providerResolver: { selection in selectionRecorder.resolve(selection) }
    )
    let audioFactory = AppTestAudioFactory()
    let viewModel = makeViewModel(
        audioFactory: audioFactory,
        profileStore: profileStore,
        pipelineTranslationEngine: translationEngine,
        whisperEngine: AppTestWhisperEngine(text: "Translate this")
    ) { _ in AppTestTranslationEngine() }

    viewModel.start()
    try await appEventually { viewModel.status == "Listening" }
    audioFactory.yield(appTestAudioChunk(timestamp: 0))
    try await appEventually { selectionRecorder.latest != nil }

    #expect(selectionRecorder.latest?.profile.id == firstID)
    #expect(selectionRecorder.latest?.model == "first-model")
    viewModel.stop()
    try await appEventually { viewModel.activeMode == .idle }
}

@Test @MainActor
func translationStartBlocksWhenSelectedProfileSecretIsMissing() async throws {
    let audioFactory = AppTestAudioFactory()
    let customID = UUID()
    let customCredential = CredentialID("custom-provider-secret")
    let custom = ProviderProfile(
        id: customID,
        name: "Custom Bearer",
        kind: .custom,
        endpoint: URL(string: "https://api.example.com/v1")!,
        apiStyle: .chatCompletions,
        authentication: .bearer(credentialID: customCredential),
        models: [.translation: ["custom-model"]]
    )
    let profileStore = AppTestProfileStore(configuration: ProviderConfiguration(
        profiles: [custom],
        selections: [
            .translation: CapabilitySelection(profileID: customID, model: "custom-model"),
        ]
    ))
    let credentials = AppTestCredentialStore() // no custom secret
    let keyStore = AppTestAPIKeyStore(storedKey: "sk-openai-present")
    let viewModel = makeViewModel(
        keyStore: keyStore,
        audioFactory: audioFactory,
        profileStore: profileStore,
        credentialStore: credentials
    ) { _ in AppTestTranslationEngine() }
    await viewModel.load()
    #expect(viewModel.apiKey == "sk-openai-present")

    viewModel.start()
    try await appEventually {
        viewModel.activeMode == .idle
            && viewModel.lastError == MLingoError.missingAPIKey.localizedDescription
    }
    #expect(audioFactory.makeCount == 0)
    #expect(viewModel.commandAvailability.canStartTranslation)
    #expect(viewModel.errorRecoveryActions == [.openSettings])
    #expect(!viewModel.errorRecoveryActions.contains(.stopTranslation))
}

@Test @MainActor
func translationDestinationDescriptionTracksResolvedProvider() async throws {
    let ollamaID = UUID()
    let ollama = OpenAICompatiblePresets.make(
        kind: .ollama,
        name: "Ollama",
        id: ollamaID,
        models: [.translation: ["llama3.2"]]
    )
    let profileStore = AppTestProfileStore(configuration: ProviderConfiguration(
        profiles: [ollama],
        selections: [
            .translation: CapabilitySelection(profileID: ollamaID, model: "llama3.2"),
        ]
    ))
    let viewModel = makeViewModel(profileStore: profileStore) { _ in
        AppTestTranslationEngine()
    }
    await viewModel.load()
    #expect(viewModel.translationDestinationDescription.contains("local"))
    #expect(viewModel.translationDestinationDescription.contains("Ollama"))
    #expect(!viewModel.translationDestinationDescription.contains("OpenAI"))

    // Remote Ollama-compatible host must not be labeled "local" just because of kind.
    let remoteOllama = ProviderProfile(
        id: UUID(),
        name: "Ollama Cloud",
        kind: .ollama,
        endpoint: URL(string: "https://ollama.example.com/v1")!,
        apiStyle: .chatCompletions,
        authentication: .none,
        models: [:]
    )
    #expect(
        MLingoViewModel.destinationDescription(for: remoteOllama)
            == "Ollama Cloud (ollama.example.com)"
    )
    #expect(!MLingoViewModel.destinationDescription(for: remoteOllama).contains("this Mac"))

    #expect(
        MLingoViewModel.destinationDescription(
            for: ProviderProfile(
                id: UUID(),
                name: "Corp Gateway",
                kind: .custom,
                endpoint: URL(string: "https://llm.corp.example/v1")!,
                apiStyle: .chatCompletions,
                authentication: .none,
                models: [:]
            )
        ) == "Corp Gateway (llm.corp.example)"
    )
    #expect(
        MLingoViewModel.destinationDescription(
            for: OpenAICompatiblePresets.make(kind: .openAI)
        ) == "OpenAI"
    )
}

@Test @MainActor
func openAIKindUsesActualRemoteHostForPrivacyDestination() {
    let proxiedOpenAI = ProviderProfile(
        id: UUID(),
        name: "OpenAI via Corp Gateway",
        kind: .openAI,
        endpoint: URL(string: "https://llm.corp.example/v1")!,
        apiStyle: .responses,
        authentication: .none,
        models: [:]
    )

    #expect(
        MLingoViewModel.destinationDescription(for: proxiedOpenAI)
            == "OpenAI via Corp Gateway (llm.corp.example)"
    )
}

@Test @MainActor
func preparingTranslationCanBeStoppedBeforePipelineStarts() async throws {
    let audioFactory = AppTestAudioFactory()
    let ollamaID = UUID()
    let ollama = OpenAICompatiblePresets.make(
        kind: .ollama,
        id: ollamaID,
        models: [.translation: ["llama3.2"]]
    )
    let profileStore = AppTestProfileStore(
        configuration: ProviderConfiguration(
            profiles: [ollama],
            selections: [
                .translation: CapabilitySelection(profileID: ollamaID, model: "llama3.2"),
            ]
        ),
        loadDelayNanoseconds: 200_000_000
    )
    let viewModel = makeViewModel(
        audioFactory: audioFactory,
        profileStore: profileStore
    ) { _ in AppTestTranslationEngine() }

    viewModel.start()
    try await appEventually { viewModel.activeMode == .preparingTranslation }
    #expect(viewModel.commandAvailability.canStop)
    #expect(!viewModel.commandAvailability.canStartTranslation)

    viewModel.stop()
    try await appEventually { viewModel.activeMode == .idle }
    #expect(viewModel.status == "Stopped")
    #expect(audioFactory.makeCount == 0)
}

@Test
func appIssuePresentationMapsTypedErrorsToContextualRecovery() {
    #expect(
        AppIssuePresentation(
            error: .systemAudioPermissionDenied,
            isTranslationActive: false
        ).actions == [.openSystemSettings]
    )
    #expect(
        AppIssuePresentation(
            error: .quotaExceeded,
            isTranslationActive: true,
            translationProviderKind: .openAI
        ).actions == [.openSettings, .stopTranslation]
    )
    #expect(
        AppIssuePresentation(
            error: .quotaExceeded,
            isTranslationActive: true,
            translationProviderKind: .openAI,
            translationProviderEndpoint: URL(string: "https://api.openai.com/v1")!
        ).actions == [.openOpenAIUsage, .stopTranslation]
    )
    #expect(
        AppIssuePresentation(
            error: .quotaExceeded,
            isTranslationActive: true,
            translationProviderKind: .openAI,
            translationProviderEndpoint: URL(string: "https://gateway.example/v1")!
        ).actions == [.openSettings, .stopTranslation]
    )
    #expect(
        AppIssuePresentation(
            error: .quotaExceeded,
            isTranslationActive: true,
            translationProviderKind: .ollama
        ).actions == [.openSettings, .stopTranslation]
    )
    #expect(
        AppIssuePresentation(
            error: .quotaExceeded,
            isTranslationActive: false,
            translationProviderKind: .custom
        ).actions == [.openSettings]
    )
    #expect(
        AppIssuePresentation(
            error: .noAudioSource,
            isTranslationActive: false
        ).actions == [.openSystemSettings]
    )
    #expect(
        AppIssuePresentation(
            error: .networkOffline,
            isTranslationActive: true
        ).actions == [.dismiss, .stopTranslation]
    )
    #expect(
        AppIssuePresentation(
            error: .requestTimedOut,
            isTranslationActive: true
        ).actions == [.dismiss]
    )
}

@Test @MainActor
func appCommandAvailabilityTracksActiveModeAndOverlayState() async throws {
    let viewModel = makeViewModel { _ in AppTestTranslationEngine() }

    #expect(viewModel.commandAvailability.canStartTranslation)
    #expect(!viewModel.commandAvailability.canStop)
    #expect(!viewModel.commandAvailability.canToggleOverlay)

    viewModel.apiKey = "sk-test"
    viewModel.start()

    #expect(!viewModel.commandAvailability.canStartTranslation)
    #expect(viewModel.commandAvailability.canStop)
    #expect(viewModel.commandAvailability.canToggleOverlay)

    viewModel.stop()
    try await appEventually { viewModel.activeMode == .idle }
}

@Test @MainActor
func translationStartWithInvalidSettingsStaysIdleAndDoesNotCreateAudio() {
    let audioFactory = AppTestAudioFactory()
    let viewModel = makeViewModel(audioFactory: audioFactory) { _ in
        AppTestTranslationEngine()
    }
    viewModel.apiKey = "sk-test"
    viewModel.settings.subtitleFontSize = 10

    viewModel.start()

    #expect(viewModel.activeMode == .idle)
    #expect(viewModel.lastError?.contains("font size") == true)
    #expect(audioFactory.makeCount == 0)
}

@Test @MainActor
func invalidSettingsSaveDoesNotTouchPreferencesOrKeychain() async {
    let settingsStore = AppTestSettingsStore()
    let keyStore = AppTestAPIKeyStore(storedKey: "sk-old")
    let viewModel = makeViewModel(settingsStore: settingsStore, keyStore: keyStore) { _ in
        AppTestTranslationEngine()
    }
    await viewModel.load()
    var invalidSettings = AppSettings()
    invalidSettings.targetLanguage = "   "

    let saved = await viewModel.save(invalidSettings, apiKey: "sk-new")

    #expect(!saved)
    #expect(await settingsStore.saveCount == 0)
    #expect(keyStore.saveCount == 0)
    #expect(keyStore.deleteCount == 0)
    #expect(keyStore.currentKey == "sk-old")
}

@Test @MainActor
func transcriptionTestStartsWithoutAnAPIKey() async throws {
    let audioFactory = AppTestAudioFactory()
    let viewModel = makeViewModel(audioFactory: audioFactory) { _ in
        AppTestTranslationEngine()
    }

    viewModel.startTranscriptionTest()

    try await appEventually { viewModel.status == "Testing transcription" }
    #expect(audioFactory.makeCount == 1)
    #expect(viewModel.activeMode == .transcriptionTest)
    viewModel.stopTranscriptionTest()
}

@Test @MainActor
func stoppingPreservesFinalPerformanceDiagnosticsUntilNextSessionStarts() async throws {
    let viewModel = makeViewModel { _ in AppTestTranslationEngine() }

    viewModel.startTranscriptionTest()
    try await appEventually { viewModel.status == "Testing transcription" }
    try await Task.sleep(for: .milliseconds(20))

    viewModel.stopTranscriptionTest()
    try await appEventually { viewModel.activeMode == .idle }

    #expect(viewModel.performanceDiagnostics.sessionDuration > 0)

    viewModel.startTranscriptionTest()
    #expect(viewModel.performanceDiagnostics == PipelinePerformanceDiagnostics())
    viewModel.stopTranscriptionTest()
    try await appEventually { viewModel.activeMode == .idle }
}

@Test @MainActor
func credentialStatusDistinguishesStoredMissingChangedAndFailedStates() async {
    let keyStore = AppTestAPIKeyStore(storedKey: "sk-stored")
    let viewModel = makeViewModel(keyStore: keyStore) { _ in AppTestTranslationEngine() }

    #expect(viewModel.credentialStatus(for: "") == .checking)
    await viewModel.load()
    #expect(viewModel.credentialStatus(for: "sk-stored") == .saved)
    #expect(viewModel.credentialStatus(for: "sk-new") == .unsavedChange)

    let emptyViewModel = makeViewModel { _ in AppTestTranslationEngine() }
    await emptyViewModel.load()
    #expect(emptyViewModel.credentialStatus(for: "") == .notSaved)

    let failedViewModel = makeViewModel(
        keyStore: AppTestAPIKeyStore(loadError: AppTestError.credentialFailed)
    ) { _ in AppTestTranslationEngine() }
    await failedViewModel.load()
    guard case .failed = failedViewModel.credentialStatus(for: "") else {
        Issue.record("Expected failed credential presentation")
        return
    }
}

@Test
func appThemeMapsToSwiftUIColorScheme() {
    #expect(AppTheme.system.preferredColorScheme == nil)
    #expect(AppTheme.light.preferredColorScheme == .light)
    #expect(AppTheme.dark.preferredColorScheme == .dark)
}

@Test @MainActor
func startPipelineEndsActiveModeWhenAudioStartupFails() async throws {
    let audioFactory = AppTestAudioFactory(startError: MLingoError.noAudioSource)
    let viewModel = makeViewModel(
        audioFactory: audioFactory,
        translationTestEngineFactory: { _ in AppTestTranslationEngine() }
    )

    viewModel.startTranscriptionTest()

    try await appEventually {
        viewModel.lastError == MLingoError.noAudioSource.localizedDescription
            && viewModel.activeMode == .idle
    }
    #expect(viewModel.status != "Testing transcription")
}

@Test @MainActor
func failedTranslationStartupRemovesStopRecoveryAfterReturningIdle() async throws {
    let audioFactory = AppTestAudioFactory(startError: MLingoError.networkOffline)
    let viewModel = makeViewModel(
        audioFactory: audioFactory,
        translationTestEngineFactory: { _ in AppTestTranslationEngine() }
    )
    viewModel.apiKey = "sk-test"

    viewModel.start()

    try await appEventually {
        viewModel.lastError == MLingoError.networkOffline.localizedDescription
            && viewModel.activeMode == .idle
    }
    #expect(viewModel.errorRecoveryActions == [.dismiss])
}

@Test @MainActor
func savingSettingsPersistsOverlayDisplaySelectionWhileIdle() async {
    let overlay = AppTestOverlayEngine()
    let viewModel = makeViewModel(
        overlayEngine: overlay,
        translationTestEngineFactory: { _ in AppTestTranslationEngine() }
    )

    let saved = await viewModel.save(
        AppSettings(),
        apiKey: "",
        overlayDisplaySelection: .display(id: "external")
    )

    #expect(saved)
    #expect(overlay.selectedDisplays == [.display(id: "external")])
}

@Test @MainActor
func viewModelExposesOverlayStateAndRoutesLiveOverlayActions() async throws {
    let overlay = AppTestOverlayEngine()
    let viewModel = makeViewModel(
        overlayEngine: overlay,
        translationTestEngineFactory: { _ in AppTestTranslationEngine() }
    )

    #expect(viewModel.overlayPresentationState === overlay.presentationState)
    viewModel.beginOverlayRepositioning()
    #expect(overlay.beginRepositioningCount == 0)

    viewModel.apiKey = "sk-test"
    viewModel.start()
    try await appEventually { viewModel.status == "Listening" }

    viewModel.setOverlayVisible(false)
    viewModel.beginOverlayRepositioning()
    viewModel.endOverlayRepositioning()
    viewModel.resetOverlayPosition()
    viewModel.selectOverlayDisplay(.automatic)

    #expect(overlay.setVisibleValues == [false])
    #expect(overlay.beginRepositioningCount == 1)
    #expect(overlay.endRepositioningCount == 1)
    #expect(overlay.resetPositionCount == 1)
    #expect(overlay.selectedDisplays == [.automatic])

    viewModel.stop()
}

@MainActor
private func makeViewModel(
    settingsStore: AppTestSettingsStore = AppTestSettingsStore(),
    keyStore: AppTestAPIKeyStore = AppTestAPIKeyStore(),
    audioFactory: AppTestAudioFactory = AppTestAudioFactory(),
    overlayEngine: AppTestOverlayEngine = AppTestOverlayEngine(),
    providerMigration: (any ProviderMigrationProtocol)? = nil,
    profileStore: (any ProviderProfileStoreProtocol)? = nil,
    credentialStore: (any ProviderCredentialStoreProtocol)? = nil,
    pipelineTranslationEngine: (any TranslationEngineProtocol)? = nil,
    whisperEngine: (any WhisperEngineProtocol)? = nil,
    translationTestEngineFactory: @escaping MLingoViewModel.TranslationTestEngineFactory
) -> MLingoViewModel {
    let pipeline = SubtitlePipeline(
        audioEngineFactory: audioFactory,
        whisperEngine: whisperEngine ?? AppTestWhisperEngine(),
        translationEngine: pipelineTranslationEngine ?? AppTestTranslationEngine(),
        overlayEngine: overlayEngine,
        settingsStore: settingsStore
    )
    return MLingoViewModel(
        settings: AppSettings(),
        settingsStore: settingsStore,
        apiKeyStore: keyStore,
        pipeline: pipeline,
        audioEngineFactory: audioFactory,
        providerMigration: providerMigration,
        profileStore: profileStore,
        credentialStore: credentialStore,
        translationTestEngineFactory: translationTestEngineFactory
    )
}

private actor AppTestProfileStore: ProviderProfileStoreProtocol {
    private var configuration: ProviderConfiguration
    private let subsequentConfiguration: ProviderConfiguration?
    private let loadDelayNanoseconds: UInt64
    private var loadCount = 0

    init(
        configuration: ProviderConfiguration,
        subsequentConfiguration: ProviderConfiguration? = nil,
        loadDelayNanoseconds: UInt64 = 0
    ) {
        self.configuration = configuration
        self.subsequentConfiguration = subsequentConfiguration
        self.loadDelayNanoseconds = loadDelayNanoseconds
    }

    func load() async throws -> ProviderConfiguration {
        if loadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: loadDelayNanoseconds)
        }
        defer { loadCount += 1 }
        if loadCount > 0, let subsequentConfiguration {
            return subsequentConfiguration
        }
        return configuration
    }

    func save(_ configuration: ProviderConfiguration) async throws {
        self.configuration = configuration
    }
}

private final class AppTestCredentialStore: ProviderCredentialStoreProtocol,
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

private final class AppTestProviderMigration: ProviderMigrationProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let action: @Sendable () throws -> Void
    private var storedCallCount = 0

    init(action: @escaping @Sendable () throws -> Void) {
        self.action = action
    }

    var callCount: Int { lock.withLock { storedCallCount } }

    func migrate(settings: AppSettings) async throws {
        lock.withLock { storedCallCount += 1 }
        try action()
    }
}

private enum AppTestError: Error {
    case loadFailed
    case saveFailed
    case credentialFailed
}

private actor AppTestSettingsStore: SettingsStoreProtocol {
    private(set) var saveCount = 0
    private var settings: AppSettings
    private let loadError: (any Error)?
    private let saveError: (any Error)?

    init(
        settings: AppSettings = AppSettings(),
        loadError: (any Error)? = nil,
        saveError: (any Error)? = nil
    ) {
        self.settings = settings
        self.loadError = loadError
        self.saveError = saveError
    }

    func load() async throws -> AppSettings {
        if let loadError { throw loadError }
        return settings
    }

    func save(_ settings: AppSettings) async throws {
        saveCount += 1
        if let saveError { throw saveError }
        self.settings = settings
    }
}

private final class AppTestAPIKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storedKey: String?
    private let loadError: (any Error)?
    private let saveFailureCallNumbers: Set<Int>
    private var _saveCount = 0
    private var _deleteCount = 0
    private var _savedValues: [String] = []

    init(
        storedKey: String? = nil,
        loadError: (any Error)? = nil,
        saveFailureCallNumbers: Set<Int> = []
    ) {
        self.storedKey = storedKey
        self.loadError = loadError
        self.saveFailureCallNumbers = saveFailureCallNumbers
    }

    var saveCount: Int { lock.withLock { _saveCount } }
    var deleteCount: Int { lock.withLock { _deleteCount } }
    var currentKey: String? { lock.withLock { storedKey } }
    var savedValues: [String] { lock.withLock { _savedValues } }

    func loadAPIKey() throws -> String? {
        if let loadError { throw loadError }
        return lock.withLock { storedKey }
    }

    func saveAPIKey(_ apiKey: String) throws {
        try lock.withLock {
            _saveCount += 1
            _savedValues.append(apiKey)
            if saveFailureCallNumbers.contains(_saveCount) {
                throw AppTestError.credentialFailed
            }
            storedKey = apiKey
        }
    }

    func deleteAPIKey() throws {
        lock.withLock {
            _deleteCount += 1
            storedKey = nil
        }
    }
}

private final class AppTestKeyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var latest: String? { lock.withLock { value } }
    func record(_ value: String) { lock.withLock { self.value = value } }
}

private actor AppTestTranslationEngine: TranslationEngineProtocol {
    private(set) var callCount = 0
    private(set) var latestRequest: TranslationRequest?

    func translate(_ request: TranslationRequest, settings: AppSettings) async throws -> SubtitleItem {
        callCount += 1
        latestRequest = request
        return SubtitleItem(
            original: request.current.text,
            translated: "Hãy triển khai dịch vụ này bằng Docker và PostgreSQL.",
            start: request.current.timestamp,
            end: request.current.timestamp + 3
        )
    }
}

private actor AppTestWhisperEngine: WhisperEngineProtocol {
    private let text: String?

    init(text: String? = nil) {
        self.text = text
    }

    func loadModel(named modelName: String) async throws {}
    func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript? {
        text.map { Transcript(text: $0, timestamp: chunk.timestamp) }
    }
}

private actor AppRecordingTranslationProvider: TranslationProvider {
    func translate(_ request: TranslationProviderRequest) async throws -> SubtitleItem {
        SubtitleItem(
            original: request.translation.current.text,
            translated: "Bản dịch",
            start: request.translation.current.timestamp,
            end: request.translation.current.timestamp + 2
        )
    }
}

private final class AppResolvedSelectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let provider: any TranslationProvider
    private var storedSelection: ResolvedProviderSelection?

    init(provider: any TranslationProvider) {
        self.provider = provider
    }

    var latest: ResolvedProviderSelection? { lock.withLock { storedSelection } }

    func resolve(_ selection: ResolvedProviderSelection) -> any TranslationProvider {
        lock.withLock { storedSelection = selection }
        return provider
    }
}

@MainActor
private final class AppTestOverlayEngine: OverlayEngineProtocol {
    let presentationState = OverlayPresentationState()
    private(set) var setVisibleValues: [Bool] = []
    private(set) var beginRepositioningCount = 0
    private(set) var endRepositioningCount = 0
    private(set) var resetPositionCount = 0
    private(set) var selectedDisplays: [OverlayDisplaySelection] = []

    func show(settings: AppSettings) {}
    func update(with subtitle: SubtitleItem, settings: AppSettings) {}
    func hide() {}
    func setVisible(_ isVisible: Bool) { setVisibleValues.append(isVisible) }
    func beginRepositioning() { beginRepositioningCount += 1 }
    func endRepositioning() { endRepositioningCount += 1 }
    func resetPosition() { resetPositionCount += 1 }
    func selectDisplay(_ selection: OverlayDisplaySelection) { selectedDisplays.append(selection) }
}

private final class AppTestAudioFactory: AudioEngineFactoryProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let startError: (any Error)?
    private(set) var makeCount = 0
    private var activeEngine: AppTestAudioEngine?

    init(startError: (any Error)? = nil) {
        self.startError = startError
    }

    func makeAudioEngine(preferredBackend: AudioCaptureBackend) -> any AudioEngineProtocol {
        lock.withLock {
            makeCount += 1
            let engine = AppTestAudioEngine(startError: startError)
            activeEngine = engine
            return engine
        }
    }

    func yield(_ chunk: AudioChunk) {
        lock.withLock { activeEngine }?.yield(chunk)
    }
}

private final class AppTestAudioEngine: AudioEngineProtocol, @unchecked Sendable {
    let chunks: AsyncStream<AudioChunk>
    let diagnostics = AsyncStream<AudioCaptureDiagnostics> { $0.finish() }
    private let continuation: AsyncStream<AudioChunk>.Continuation
    private let startError: (any Error)?

    init(startError: (any Error)? = nil) {
        let (chunks, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.chunks = chunks
        self.continuation = continuation
        self.startError = startError
    }

    var state: AudioCaptureState { get async { .idle } }
    func start() async throws {
        if let startError { throw startError }
    }
    func stop() async {}

    func yield(_ chunk: AudioChunk) {
        continuation.yield(chunk)
    }
}

private func appTestAudioChunk(timestamp: TimeInterval) -> AudioChunk {
    AudioChunk(
        samples: Array(repeating: 0.05, count: 48_000),
        sampleRate: 16_000,
        channelCount: 1,
        timestamp: timestamp,
        duration: 3
    )
}

@MainActor
private func appEventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition was not met before timeout")
    throw AppTestError.saveFailed
}
