import Foundation
import MLingoCore
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

@MainActor
private func makeViewModel(
    settingsStore: AppTestSettingsStore = AppTestSettingsStore(),
    keyStore: AppTestAPIKeyStore = AppTestAPIKeyStore(),
    audioFactory: AppTestAudioFactory = AppTestAudioFactory(),
    translationTestEngineFactory: @escaping MLingoViewModel.TranslationTestEngineFactory
) -> MLingoViewModel {
    let pipeline = SubtitlePipeline(
        audioEngineFactory: audioFactory,
        whisperEngine: AppTestWhisperEngine(),
        translationEngine: AppTestTranslationEngine(),
        overlayEngine: AppTestOverlayEngine(),
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
    case saveFailed
}

private actor AppTestSettingsStore: SettingsStoreProtocol {
    private(set) var saveCount = 0
    private let saveError: (any Error)?

    init(saveError: (any Error)? = nil) {
        self.saveError = saveError
    }

    func load() async throws -> AppSettings { AppSettings() }
    func save(_ settings: AppSettings) async throws {
        saveCount += 1
        if let saveError { throw saveError }
    }
}

private final class AppTestAPIKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var saveCount = 0
    func loadAPIKey() throws -> String? { nil }
    func saveAPIKey(_ apiKey: String) throws { lock.withLock { saveCount += 1 } }
    func deleteAPIKey() throws {}
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
    func show() {}
    func update(with subtitle: SubtitleItem, settings: AppSettings) {}
    func hide() {}
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
