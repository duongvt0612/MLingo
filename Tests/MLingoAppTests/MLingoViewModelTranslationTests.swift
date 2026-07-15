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
    #expect(audioFactory.makeCount == 0)
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
    translationTestEngineFactory: @escaping MLingoViewModel.TranslationTestEngineFactory
) -> MLingoViewModel {
    let pipeline = SubtitlePipeline(
        audioEngineFactory: audioFactory,
        whisperEngine: AppTestWhisperEngine(),
        translationEngine: AppTestTranslationEngine(),
        overlayEngine: overlayEngine,
        settingsStore: settingsStore
    )
    return MLingoViewModel(
        settings: AppSettings(),
        settingsStore: settingsStore,
        apiKeyStore: keyStore,
        pipeline: pipeline,
        audioEngineFactory: audioFactory,
        translationTestEngineFactory: translationTestEngineFactory
    )
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
    func loadModel(named modelName: String) async throws {}
    func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript? { nil }
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

    init(startError: (any Error)? = nil) {
        self.startError = startError
    }

    func makeAudioEngine(preferredBackend: AudioCaptureBackend) -> any AudioEngineProtocol {
        lock.withLock { makeCount += 1 }
        return AppTestAudioEngine(startError: startError)
    }
}

private final class AppTestAudioEngine: AudioEngineProtocol, @unchecked Sendable {
    let chunks = AsyncStream<AudioChunk> { $0.finish() }
    let diagnostics = AsyncStream<AudioCaptureDiagnostics> { $0.finish() }
    private let startError: (any Error)?

    init(startError: (any Error)? = nil) {
        self.startError = startError
    }

    var state: AudioCaptureState { get async { .idle } }
    func start() async throws {
        if let startError { throw startError }
    }
    func stop() async {}
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
