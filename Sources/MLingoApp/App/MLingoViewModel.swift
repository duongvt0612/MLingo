import Foundation
import MLingoCore
import Observation

@MainActor
@Observable
final class MLingoViewModel {
    typealias TranslationTestEngineFactory = (String) -> any TranslationEngineProtocol

    struct TranslationTestResult: Equatable {
        let original: String
        let translated: String
        let model: String
        let latency: TimeInterval
    }

    enum TranslationTestState: Equatable {
        case idle
        case running
        case success(TranslationTestResult)
        case failure(String)
    }

    static let translationTestFixture = "Let's deploy this service with Docker and PostgreSQL."

    enum ActiveMode: Equatable {
        case idle
        case soundTest
        case transcriptionTest
        case translation
    }

    enum CredentialState: Equatable {
        case unknown
        case notStored
        case stored
        case failed(String)
    }

    var settings: AppSettings
    var apiKey: String = ""
    private(set) var activeMode: ActiveMode = .idle
    var status = "Ready"
    var lastError: String?
    var lastWarning: String?
    private(set) var credentialState: CredentialState = .unknown
    private(set) var isSavingSettings = false
    private(set) var translationTestState: TranslationTestState = .idle
    private(set) var transcriptionEntries: [TranscriptLogEntry] = []
    var audioDiagnostics = AudioCaptureDiagnostics()
    var whisperDiagnostics = WhisperDiagnostics()

    var isRunning: Bool { activeMode == .translation }
    var isTestingSound: Bool { activeMode == .soundTest }
    var isTestingTranscription: Bool { activeMode == .transcriptionTest }
    var isActive: Bool { activeMode != .idle }
    var isTranslationTestRunning: Bool { translationTestState == .running }
    var overlayPresentationState: OverlayPresentationState {
        pipeline.overlayPresentationState
    }

    func credentialStatus(for candidateAPIKey: String) -> CredentialStatus {
        let candidate = candidateAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate == apiKey else { return .unsavedChange }

        switch credentialState {
        case .unknown:
            return .checking
        case .notStored:
            return .notSaved
        case .stored:
            return .saved
        case .failed(let message):
            return .failed(message)
        }
    }

    private let settingsStore: SettingsStoreProtocol
    private let apiKeyStore: APIKeyStoreProtocol
    private let pipeline: SubtitlePipeline
    private let audioEngineFactory: any AudioEngineFactoryProtocol
    private let translationTestEngineFactory: TranslationTestEngineFactory
    private var startTask: Task<Void, Never>?
    private var activeSessionID = UUID()
    private var soundTestEngine: (any AudioEngineProtocol)?
    private var soundDiagnosticsTask: Task<Void, Never>?

    init(
        settings: AppSettings,
        settingsStore: SettingsStoreProtocol,
        apiKeyStore: APIKeyStoreProtocol,
        pipeline: SubtitlePipeline,
        audioEngineFactory: any AudioEngineFactoryProtocol,
        translationTestEngineFactory: @escaping TranslationTestEngineFactory
    ) {
        self.settings = settings
        self.settingsStore = settingsStore
        self.apiKeyStore = apiKeyStore
        self.pipeline = pipeline
        self.audioEngineFactory = audioEngineFactory
        self.translationTestEngineFactory = translationTestEngineFactory
        whisperDiagnostics.modelID = settings.whisperModel
    }

    static func live() -> MLingoViewModel {
        let settingsStore = UserDefaultsSettingsStore()
        let apiKeyStore = KeychainAPIKeyStore()
        let overlay = FloatingSubtitleWindowController()
        let translation = OpenAITranslationEngine(apiKeyStore: apiKeyStore)
        let audioEngineFactory = SystemAudioEngineFactory()
        let pipeline = SubtitlePipeline(
            audioEngineFactory: audioEngineFactory,
            whisperEngine: MLXWhisperEngine(),
            translationEngine: translation,
            overlayEngine: overlay,
            settingsStore: settingsStore
        )

        return MLingoViewModel(
            settings: AppSettings(),
            settingsStore: settingsStore,
            apiKeyStore: apiKeyStore,
            pipeline: pipeline,
            audioEngineFactory: audioEngineFactory,
            translationTestEngineFactory: { apiKey in
                OpenAITranslationEngine(
                    apiKeyStore: TransientAPIKeyStore(apiKey: apiKey)
                )
            }
        )
    }

    func load() async {
        var settingsLoadError: String?
        do {
            settings = try await settingsStore.load()
            whisperDiagnostics.modelID = settings.whisperModel
        } catch {
            settingsLoadError = error.localizedDescription
            lastError = settingsLoadError
        }

        do {
            let loadedAPIKey = try apiKeyStore.loadAPIKey()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            apiKey = loadedAPIKey
            credentialState = loadedAPIKey.isEmpty ? .notStored : .stored
        } catch {
            let credentialError = error.localizedDescription
            apiKey = ""
            credentialState = .failed(credentialError)
            if let settingsLoadError {
                lastError = "\(settingsLoadError)\n\(credentialError)"
            } else {
                lastError = credentialError
            }
        }
    }

    @discardableResult
    func save() async -> Bool {
        await save(settings, apiKey: apiKey)
    }

    @discardableResult
    func save(
        _ candidateSettings: AppSettings,
        apiKey candidateAPIKey: String? = nil,
        overlayDisplaySelection: OverlayDisplaySelection? = nil
    ) async -> Bool {
        guard !isSavingSettings else { return false }
        isSavingSettings = true
        defer { isSavingSettings = false }

        let validation = AppSettingsValidation(settings: candidateSettings)
        guard validation.isValid else {
            lastError = MLingoError.invalidSettings(
                validation.firstError ?? "Review Settings before saving."
            ).localizedDescription
            return false
        }

        let normalizedSettings = validation.normalizedSettings
        let trimmedAPIKey = (candidateAPIKey ?? apiKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previousAPIKey = apiKey
        let previousCredentialState = credentialState
        let credentialChanged = trimmedAPIKey != previousAPIKey

        do {
            if credentialChanged {
                try persistAPIKey(trimmedAPIKey)
            }
        } catch {
            credentialState = previousCredentialState
            lastError = error.localizedDescription
            return false
        }

        do {
            try await settingsStore.save(normalizedSettings)
        } catch {
            if credentialChanged {
                do {
                    try persistAPIKey(previousAPIKey)
                    credentialState = previousCredentialState
                } catch {
                    MLingoLogger.settings.error("Credential rollback failed; operation=rollback")
                    credentialState = .failed(
                        MLingoError.credentialStoreFailure(
                            operation: .rollback,
                            status: -1
                        ).localizedDescription
                    )
                }
            }
            lastError = error.localizedDescription
            return false
        }

        if let overlayDisplaySelection {
            pipeline.selectOverlayDisplay(overlayDisplaySelection)
        }
        apiKey = trimmedAPIKey
        credentialState = trimmedAPIKey.isEmpty ? .notStored : .stored
        settings = normalizedSettings
        whisperDiagnostics.modelID = normalizedSettings.whisperModel
        status = "Settings saved"
        lastError = nil
        return true
    }

    func testTranslation(apiKey candidateAPIKey: String, settings candidateSettings: AppSettings) async {
        guard !isActive else {
            translationTestState = .failure("Stop the active session before testing OpenAI settings.")
            return
        }

        let validation = OpenAISettingsValidation(
            apiKey: candidateAPIKey,
            settings: candidateSettings
        )
        guard validation.isValid else {
            translationTestState = .failure(validation.firstError ?? "Review the OpenAI settings.")
            return
        }

        let trimmedAPIKey = candidateAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSettings = validation.normalizedSettings
        let model = normalizedSettings.openAIModel
        translationTestState = .running
        let start = ContinuousClock.now

        do {
            let engine = translationTestEngineFactory(trimmedAPIKey)
            let subtitle = try await engine.translate(
                TranslationRequest(
                    current: Transcript(text: Self.translationTestFixture, timestamp: 0)
                ),
                settings: normalizedSettings
            )
            try Task.checkCancellation()
            translationTestState = .success(
                TranslationTestResult(
                    original: subtitle.original,
                    translated: subtitle.translated,
                    model: model,
                    latency: start.duration(to: .now).timeInterval
                )
            )
        } catch is CancellationError {
            translationTestState = .idle
        } catch {
            translationTestState = .failure(error.localizedDescription)
        }
    }

    func resetTranslationTest() {
        guard !isTranslationTestRunning else { return }
        translationTestState = .idle
    }

    func start() {
        let validation = AppSettingsValidation(settings: settings)
        guard validation.isValid else {
            lastError = MLingoError.invalidSettings(
                validation.firstError ?? "Review Settings before starting translation."
            ).localizedDescription
            status = "Settings need attention"
            return
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = MLingoError.missingAPIKey.localizedDescription
            status = "Settings need attention"
            return
        }
        startPipeline(mode: .translation)
    }

    func stop() {
        guard activeMode == .translation else { return }
        stopActiveMode(statusAfterStop: "Stopped")
    }

    func setOverlayVisible(_ isVisible: Bool) {
        guard isRunning else { return }
        pipeline.setOverlayVisible(isVisible)
    }

    func beginOverlayRepositioning() {
        guard isRunning else { return }
        pipeline.beginOverlayRepositioning()
    }

    func endOverlayRepositioning() {
        guard isRunning else { return }
        pipeline.endOverlayRepositioning()
    }

    func resetOverlayPosition() {
        guard isRunning else { return }
        pipeline.resetOverlayPosition()
    }

    func selectOverlayDisplay(_ selection: OverlayDisplaySelection) {
        pipeline.selectOverlayDisplay(selection)
    }

    func startTranscriptionTest() {
        startPipeline(mode: .transcriptionOnly)
    }

    func stopTranscriptionTest() {
        guard activeMode == .transcriptionTest else { return }
        stopActiveMode(statusAfterStop: "Transcription test stopped")
    }

    func startSoundTest() {
        guard activeMode == .idle, startTask == nil else { return }

        let sessionID = UUID()
        activeSessionID = sessionID
        activeMode = .soundTest
        status = "Testing system audio"
        lastError = nil
        lastWarning = nil
        audioDiagnostics = AudioCaptureDiagnostics(state: .requestingPermission)

        startTask = Task {
            defer { clearStartTask(for: sessionID) }

            let audioEngine = audioEngineFactory.makeAudioEngine(
                preferredBackend: settings.audioCaptureBackend
            )
            soundTestEngine = audioEngine
            soundDiagnosticsTask = Task { [weak self, audioEngine, sessionID] in
                for await diagnostics in audioEngine.diagnostics {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard self?.activeSessionID == sessionID else { return }
                        self?.audioDiagnostics = diagnostics
                    }
                }
            }

            do {
                try await audioEngine.start()
                guard isCurrentSession(sessionID, mode: .soundTest) else {
                    await audioEngine.stop()
                    return
                }
            } catch {
                guard isCurrentSession(sessionID, mode: .soundTest) else { return }
                lastError = error.localizedDescription
                status = "Sound test needs attention"
                await finishActiveMode(statusAfterStop: nil)
            }
        }
    }

    func stopSoundTest() {
        guard activeMode == .soundTest else { return }
        stopActiveMode(statusAfterStop: "Sound test stopped")
    }

    private func startPipeline(mode: SubtitlePipelineMode) {
        guard activeMode == .idle, startTask == nil else { return }

        let viewMode: ActiveMode = mode == .translation ? .translation : .transcriptionTest
        let sessionID = UUID()
        let startingStatus = mode == .translation ? "Starting translation" : "Starting transcription test"
        activeSessionID = sessionID
        activeMode = viewMode
        status = "Saving settings"
        lastError = nil
        lastWarning = nil
        transcriptionEntries = []
        whisperDiagnostics = WhisperDiagnostics(
            modelState: .loading,
            modelID: settings.whisperModel
        )

        startTask = Task {
            defer { clearStartTask(for: sessionID) }

            guard await save() else {
                guard isCurrentSession(sessionID, mode: viewMode) else { return }
                await finishActiveMode(statusAfterStop: "Settings need attention")
                return
            }
            guard isCurrentSession(sessionID, mode: viewMode) else { return }
            status = startingStatus

            let started = await pipeline.start(
                mode: mode,
                onError: { [weak self, sessionID] message in
                    Task { @MainActor in
                        guard self?.activeSessionID == sessionID else { return }
                        self?.lastError = message
                        self?.status = "Needs attention"
                    }
                },
                onWarning: { [weak self, sessionID] message in
                    Task { @MainActor in
                        guard self?.activeSessionID == sessionID else { return }
                        self?.lastWarning = message
                    }
                },
                onAudioDiagnostics: { [weak self, sessionID] diagnostics in
                    await MainActor.run {
                        guard self?.activeSessionID == sessionID else { return }
                        self?.audioDiagnostics = diagnostics
                    }
                },
                onTranscript: { [weak self, sessionID] transcript in
                    await MainActor.run {
                        guard self?.activeSessionID == sessionID else { return }
                        self?.appendTranscript(transcript)
                    }
                },
                onWhisperDiagnostics: { [weak self, sessionID] diagnostics in
                    await MainActor.run {
                        guard self?.activeSessionID == sessionID else { return }
                        self?.whisperDiagnostics = diagnostics
                        if diagnostics.modelState == .loading {
                            self?.status = "Loading Whisper model"
                        }
                    }
                }
            )
            guard isCurrentSession(sessionID, mode: viewMode) else { return }
            guard started else {
                await finishActiveMode(statusAfterStop: "Needs attention")
                return
            }
            status = mode == .translation ? "Listening" : "Testing transcription"
        }
    }

    private func stopActiveMode(statusAfterStop: String) {
        Task {
            await finishActiveMode(statusAfterStop: statusAfterStop)
        }
    }

    private func finishActiveMode(statusAfterStop: String?) async {
        let mode = activeMode
        activeSessionID = UUID()
        activeMode = .idle
        let pendingStartTask = startTask
        startTask = nil
        pendingStartTask?.cancel()

        if mode == .soundTest {
            await soundTestEngine?.stop()
            soundDiagnosticsTask?.cancel()
            soundDiagnosticsTask = nil
            soundTestEngine = nil
        } else if mode == .translation || mode == .transcriptionTest {
            await pipeline.stop()
        }

        if let statusAfterStop {
            status = statusAfterStop
        }
    }

    private func clearStartTask(for sessionID: UUID) {
        if activeSessionID == sessionID {
            startTask = nil
        }
    }

    private func appendTranscript(_ transcript: Transcript) {
        let trimmedText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let trimmedTranscript = Transcript(
            id: transcript.id,
            text: trimmedText,
            timestamp: transcript.timestamp
        )
        transcriptionEntries.append(TranscriptLogEntry(transcript: trimmedTranscript))
        if transcriptionEntries.count > 500 {
            transcriptionEntries.removeFirst(transcriptionEntries.count - 500)
        }
    }

    private func isCurrentSession(_ sessionID: UUID, mode: ActiveMode) -> Bool {
        activeSessionID == sessionID && activeMode == mode && !Task.isCancelled
    }

    private func persistAPIKey(_ value: String) throws {
        if value.isEmpty {
            try apiKeyStore.deleteAPIKey()
        } else {
            try apiKeyStore.saveAPIKey(value)
        }
    }
}

struct OpenAISettingsValidation: Equatable {
    let apiKeyError: String?
    let modelError: String?
    let sourceLanguageError: String?
    let targetLanguageError: String?
    let normalizedSettings: AppSettings
    private let settingsFirstError: String?

    init(apiKey: String, settings: AppSettings) {
        let validation = AppSettingsValidation(settings: settings)
        apiKeyError = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Enter an OpenAI Platform API key."
            : nil
        modelError = validation.errors[.openAIModel]
        sourceLanguageError = validation.errors[.sourceLanguage]
        targetLanguageError = validation.errors[.targetLanguage]
        normalizedSettings = validation.normalizedSettings
        settingsFirstError = validation.firstError
    }

    var isValid: Bool {
        apiKeyError == nil && hasValidTranslationSettings
    }

    var hasValidTranslationSettings: Bool {
        settingsFirstError == nil
    }

    var firstError: String? {
        apiKeyError ?? settingsFirstError
    }
}

private final class TransientAPIKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    private var apiKey: String?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func loadAPIKey() throws -> String? { apiKey }
    func saveAPIKey(_ apiKey: String) throws { self.apiKey = apiKey }
    func deleteAPIKey() throws { apiKey = nil }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
