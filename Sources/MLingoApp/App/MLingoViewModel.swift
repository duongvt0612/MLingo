import Foundation
import MLingoCore
import Observation
import OSLog

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
        /// Profile resolve / credential preflight before the runtime starts.
        case preparingTranslation
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

    enum TranslationProviderReadiness: Equatable {
        case checking
        case ready(profileName: String, model: String)
        case needsAttention(String)
    }

    var settings: AppSettings
    var apiKey: String = ""
    private(set) var activeMode: ActiveMode = .idle
    var status = "Ready"
    var lastError: String?
    var lastWarning: String?
    private(set) var errorRecoveryActions: [AppRecoveryAction] = []
    private(set) var credentialState: CredentialState = .unknown
    private(set) var isSavingSettings = false
    private(set) var translationTestState: TranslationTestState = .idle
    private(set) var transcriptionEntries: [TranscriptLogEntry] = []
    /// User-facing destination for privacy copy (local / OpenAI / custom host).
    private(set) var translationDestinationDescription =
        "a configured translation provider"
    private(set) var translationProviderReadiness: TranslationProviderReadiness = .checking
    var audioDiagnostics = AudioCaptureDiagnostics()
    var whisperDiagnostics = WhisperDiagnostics()
    var performanceDiagnostics = PipelinePerformanceDiagnostics()

    var isRunning: Bool { activeMode == .translation }
    /// True while preflighting or running a translation session (Stop should cancel both).
    var isTranslationSession: Bool {
        activeMode == .preparingTranslation || activeMode == .translation
    }
    var isTestingSound: Bool { activeMode == .soundTest }
    var isTestingTranscription: Bool { activeMode == .transcriptionTest }
    var isActive: Bool { activeMode != .idle }
    var isTranslationTestRunning: Bool { translationTestState == .running }
    var commandAvailability: AppCommandAvailability {
        AppCommandAvailability(activeMode: activeMode)
    }
    var overlayPresentationState: OverlayPresentationState {
        runtime.overlayPresentationState
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
    private let runtime: any SessionRuntimeProtocol
    private let audioEngineFactory: any AudioEngineFactoryProtocol
    private let providerMigration: (any ProviderMigrationProtocol)?
    private let profileStore: (any ProviderProfileStoreProtocol)?
    private let credentialStore: (any ProviderCredentialStoreProtocol)?
    private let translationTestEngineFactory: TranslationTestEngineFactory
    private var startTask: Task<Void, Never>?
    private var activeSessionID = UUID()
    private var soundTestEngine: (any AudioEngineProtocol)?
    private var soundDiagnosticsTask: Task<Void, Never>?
    /// Provider kind for the active/preparing translation selection (recovery UI).
    private var activeTranslationProviderKind: ProviderKind?
    /// Provider endpoint from the same immutable selection used by the active session.
    private var activeTranslationProviderEndpoint: URL?
    /// Credential currently used by the active/preparing translation session.
    private var activeTranslationCredentialID: CredentialID?

    init(
        settings: AppSettings,
        settingsStore: SettingsStoreProtocol,
        apiKeyStore: APIKeyStoreProtocol,
        runtime: any SessionRuntimeProtocol,
        audioEngineFactory: any AudioEngineFactoryProtocol,
        providerMigration: (any ProviderMigrationProtocol)? = nil,
        profileStore: (any ProviderProfileStoreProtocol)? = nil,
        credentialStore: (any ProviderCredentialStoreProtocol)? = nil,
        translationTestEngineFactory: @escaping TranslationTestEngineFactory
    ) {
        self.settings = settings
        self.settingsStore = settingsStore
        self.apiKeyStore = apiKeyStore
        self.runtime = runtime
        self.audioEngineFactory = audioEngineFactory
        self.providerMigration = providerMigration
        self.profileStore = profileStore
        self.credentialStore = credentialStore
        self.translationTestEngineFactory = translationTestEngineFactory
        whisperDiagnostics.modelID = settings.whisperModel
    }

    static func live() -> MLingoViewModel {
        let settingsStore = UserDefaultsSettingsStore()
        let legacyAPIKeyStore = KeychainAPIKeyStore()
        let profileStore = UserDefaultsProviderProfileStore()
        let credentialStore = KeychainProviderCredentialStore()
        let apiKeyStore = ProviderAPIKeyStoreAdapter(credentialStore: credentialStore)
        let migration = LegacyOpenAIProviderMigrator(
            profileStore: profileStore,
            credentialStore: credentialStore,
            legacyAPIKeyStore: legacyAPIKeyStore
        )
        let overlay = FloatingSubtitleWindowController()
        let builtInMLXProvider = BuiltInMLXProvider()
        let translation = ProviderTranslationEngine(
            profileStore: profileStore,
            providerResolver: { selection in
                if selection.profile.kind == .builtInMLX,
                   selection.profile.apiStyle == .native {
                    return builtInMLXProvider
                }
                return try OpenAICompatibleTranslationProviderFactory.make(
                    selection: selection,
                    credentialStore: credentialStore
                )
            }
        )
        let audioEngineFactory = SystemAudioEngineFactory()
        let runtime = SessionOrchestrator(
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
            runtime: runtime,
            audioEngineFactory: audioEngineFactory,
            providerMigration: migration,
            profileStore: profileStore,
            credentialStore: credentialStore,
            translationTestEngineFactory: { apiKey in
                OpenAITranslationEngine(
                    apiKeyStore: TransientAPIKeyStore(apiKey: apiKey)
                )
            }
        )
    }

    func load() async {
        var configurationLoadError: String?
        do {
            settings = try await settingsStore.load()
            whisperDiagnostics.modelID = settings.whisperModel
        } catch {
            configurationLoadError = error.localizedDescription
            present(error)
        }

        if configurationLoadError == nil, let providerMigration {
            do {
                try await providerMigration.migrate(settings: settings)
            } catch {
                configurationLoadError = error.localizedDescription
                present(error)
            }
        }

        do {
            let loadedAPIKey = try apiKeyStore.loadAPIKey()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            apiKey = loadedAPIKey
            credentialState = loadedAPIKey.isEmpty ? .notStored : .stored
            if configurationLoadError == nil {
                clearError()
            }
        } catch {
            let credentialError = error.localizedDescription
            apiKey = ""
            credentialState = .failed(credentialError)
            if let configurationLoadError {
                presentMessage(
                    "\(configurationLoadError)\n\(credentialError)",
                    actions: [.openSettings]
                )
            } else {
                present(error)
            }
        }

        await refreshTranslationDestinationDescription()
    }

    func makeSettingsEditor() async throws -> SettingsEditorViewModel {
        guard let profileStore, let credentialStore else {
            throw MLingoError.invalidTranslationConfiguration(
                "Provider settings storage is unavailable."
            )
        }
        let persistence = SettingsPersistenceCoordinator(
            settingsStore: settingsStore,
            profileStore: profileStore,
            credentialStore: credentialStore
        )
        let snapshot = try await persistence.load(
            overlaySelection: overlayPresentationState.selectedDisplay
        )
        return SettingsEditorViewModel(
            snapshot: snapshot,
            credentialStore: credentialStore,
            connectionProbe: OpenAICompatibleConnectionProbe(),
            persistenceCoordinator: persistence,
            activeCredentialID: { [weak self] in
                self?.activeTranslationCredentialID
            },
            applyOverlay: { [weak self] selection in
                self?.runtime.selectOverlayDisplay(selection)
            },
            onCommit: { [weak self] snapshot in
                self?.applyCommittedSettings(snapshot)
            }
        )
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
            present(MLingoError.invalidSettings(
                validation.firstError ?? "Review Settings before saving."
            ))
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
            present(error)
            return false
        }

        do {
            try await providerMigration?.migrate(settings: normalizedSettings)
        } catch {
            if credentialChanged {
                try? persistAPIKey(previousAPIKey)
            }
            credentialState = previousCredentialState
            present(error)
            return false
        }

        do {
            try await settingsStore.save(normalizedSettings)
        } catch {
            try? await providerMigration?.migrate(settings: settings)
            if credentialChanged {
                do {
                    try persistAPIKey(previousAPIKey)
                    credentialState = previousCredentialState
                } catch {
                    let rollbackStatus: Int32
                    if let credentialError = error as? MLingoError,
                       case .credentialStoreFailure(_, let status) = credentialError
                    {
                        rollbackStatus = status
                    } else {
                        rollbackStatus = -1
                    }
                    let rollbackError = error.localizedDescription
                    MLingoLogger.settings.error(
                        "Credential rollback failed; operation=rollback status=\(rollbackStatus) error=\(rollbackError, privacy: .public)"
                    )
                    credentialState = .failed(
                        MLingoError.credentialStoreFailure(
                            operation: .rollback,
                            status: rollbackStatus
                        ).localizedDescription
                    )
                }
            }
            present(error)
            return false
        }

        if let overlayDisplaySelection {
            runtime.selectOverlayDisplay(overlayDisplaySelection)
        }
        apiKey = trimmedAPIKey
        credentialState = trimmedAPIKey.isEmpty ? .notStored : .stored
        settings = normalizedSettings
        whisperDiagnostics.modelID = normalizedSettings.whisperModel
        status = "Settings saved"
        clearError()
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
            present(MLingoError.invalidSettings(
                validation.firstError ?? "Review Settings before starting translation."
            ))
            status = "Settings need attention"
            return
        }
        guard activeMode == .idle, startTask == nil else { return }

        // Legacy path (no profile store): OpenAI key is always required.
        guard profileStore != nil else {
            activeTranslationProviderKind = .openAI
            activeTranslationProviderEndpoint = URL(string: "https://api.openai.com/v1")
            guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                present(.missingAPIKey)
                status = "Settings need attention"
                return
            }
            startRuntime(kind: .translation)
            return
        }

        // Profile-aware path: resolve selection, verify the profile's own credential ID.
        let sessionID = UUID()
        activeSessionID = sessionID
        activeMode = .preparingTranslation
        status = "Preparing translation"
        clearError()
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeSessionID == sessionID,
                   self.activeMode == .preparingTranslation
                {
                    self.startTask = nil
                }
            }

            do {
                try Task.checkCancellation()
                guard await self.save() else {
                    guard self.isCurrentSession(sessionID, mode: .preparingTranslation) else {
                        return
                    }
                    self.activeMode = .idle
                    self.activeTranslationProviderKind = nil
                    self.activeTranslationProviderEndpoint = nil
                    self.activeTranslationCredentialID = nil
                    self.startTask = nil
                    self.status = "Settings need attention"
                    return
                }
                try Task.checkCancellation()
                let selection = try await self.resolveTranslationSelection()
                try Task.checkCancellation()
                guard self.isCurrentSession(sessionID, mode: .preparingTranslation) else {
                    return
                }

                self.activeTranslationProviderKind = selection.profile.kind
                self.activeTranslationProviderEndpoint = selection.profile.endpoint
                self.activeTranslationCredentialID = selection.profile.authentication.credentialID
                self.applyTranslationDestination(from: selection.profile)
                try self.ensureCredentialPresent(for: selection.profile.authentication)
                try Task.checkCancellation()
                guard self.isCurrentSession(sessionID, mode: .preparingTranslation) else {
                    return
                }

                self.startTask = nil
                // Promote preparing → runtime start with a fresh session.
                self.activeMode = .idle
                self.startRuntime(
                    kind: .translation,
                    translationSelection: selection,
                    settingsArePersisted: true
                )
            } catch is CancellationError {
                if self.isCurrentSession(sessionID, mode: .preparingTranslation) {
                    self.activeMode = .idle
                    self.status = "Stopped"
                    self.activeTranslationProviderKind = nil
                    self.activeTranslationProviderEndpoint = nil
                    self.activeTranslationCredentialID = nil
                    self.startTask = nil
                }
            } catch {
                if self.isCurrentSession(sessionID, mode: .preparingTranslation) {
                    // Return to idle before presenting so recovery does not offer Stop.
                    self.activeMode = .idle
                    self.activeTranslationProviderKind = nil
                    self.activeTranslationProviderEndpoint = nil
                    self.activeTranslationCredentialID = nil
                    self.startTask = nil
                    self.status = "Settings need attention"
                    self.present(error)
                }
            }
        }
    }

    /// Resolves the registry translation selection (profile + model).
    func resolveTranslationSelection() async throws -> ResolvedProviderSelection {
        guard let profileStore else {
            throw MLingoError.invalidTranslationConfiguration(
                "No provider profile store is configured."
            )
        }
        let configuration = try await profileStore.load()
        return try ProviderRegistry(
            profiles: configuration.profiles,
            selections: configuration.selections
        ).resolve(.translation)
    }

    /// Verifies the secret for the selected profile's auth, not the OpenAI default key.
    func ensureCredentialPresent(for authentication: ProviderAuthentication) throws {
        guard let credentialID = authentication.credentialID else { return }

        let secret: String?
        if let credentialStore {
            secret = try credentialStore.loadCredential(for: credentialID)
        } else if credentialID == ProviderDefaults.openAICredentialID {
            // Legacy / test path without a multi-credential store.
            secret = try apiKeyStore.loadAPIKey() ?? apiKey
        } else {
            secret = nil
        }

        let trimmed = secret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            throw MLingoError.missingAPIKey
        }
    }

    func refreshTranslationDestinationDescription() async {
        guard profileStore != nil else {
            translationDestinationDescription = "OpenAI"
            activeTranslationProviderKind = .openAI
            activeTranslationProviderEndpoint = URL(string: "https://api.openai.com/v1")
            translationProviderReadiness = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .needsAttention("Credential missing for OpenAI.")
                : .ready(profileName: "OpenAI", model: settings.openAIModel)
            return
        }
        translationProviderReadiness = .checking
        do {
            let selection = try await resolveTranslationSelection()
            activeTranslationProviderKind = selection.profile.kind
            activeTranslationProviderEndpoint = selection.profile.endpoint
            applyTranslationDestination(from: selection.profile)
            do {
                try ensureCredentialPresent(for: selection.profile.authentication)
                translationProviderReadiness = .ready(
                    profileName: selection.profile.name,
                    model: selection.model
                )
            } catch let error as MLingoError {
                switch error {
                case .missingAPIKey:
                    translationProviderReadiness = .needsAttention(
                        "Credential missing for \(selection.profile.name)."
                    )
                default:
                    translationProviderReadiness = .needsAttention(error.localizedDescription)
                }
            } catch {
                translationProviderReadiness = .needsAttention(error.localizedDescription)
            }
        } catch {
            translationDestinationDescription = "a configured translation provider"
            translationProviderReadiness = .needsAttention(error.localizedDescription)
        }
    }

    func applyTranslationDestination(from profile: ProviderProfile) {
        translationDestinationDescription = Self.destinationDescription(for: profile)
    }

    static func destinationDescription(for profile: ProviderProfile) -> String {
        // Only built-in/system are local by kind. Network kinds use real loopback host checks.
        switch profile.kind {
        case .builtInMLX:
            return "the local \(profile.name) model on this Mac"
        case .system:
            return "the system translation service"
        case .openAI, .ollama, .lmStudio, .custom:
            break
        }

        if let endpoint = profile.endpoint, endpoint.isLoopbackHost {
            return "the local \(profile.name) endpoint on this Mac"
        }
        if profile.kind == .openAI,
           profile.endpoint?.isOfficialOpenAIAPIEndpoint == true {
            return "OpenAI"
        }
        if let host = profile.endpoint?.host, !host.isEmpty {
            return "\(profile.name) (\(host))"
        }
        return profile.name
    }

    func stop() {
        switch activeMode {
        case .preparingTranslation:
            cancelPreparingTranslation(statusAfterStop: "Stopped")
        case .translation:
            stopActiveMode(statusAfterStop: "Stopped")
        default:
            break
        }
    }

    func stopCurrentActivity() {
        switch activeMode {
        case .idle:
            break
        case .preparingTranslation:
            cancelPreparingTranslation(statusAfterStop: "Stopped")
        case .soundTest:
            stopSoundTest()
        case .transcriptionTest:
            stopTranscriptionTest()
        case .translation:
            stop()
        }
    }

    private func cancelPreparingTranslation(statusAfterStop: String) {
        let pending = startTask
        startTask = nil
        pending?.cancel()
        activeMode = .idle
        activeTranslationProviderKind = nil
        activeTranslationProviderEndpoint = nil
        activeTranslationCredentialID = nil
        status = statusAfterStop
        errorRecoveryActions.removeAll { $0 == .stopTranslation }
    }

    func toggleOverlayVisibility() {
        guard isRunning else { return }
        setOverlayVisible(!overlayPresentationState.isVisible)
    }

    func dismissError() {
        clearError()
    }

    func setOverlayVisible(_ isVisible: Bool) {
        guard isRunning else { return }
        runtime.setOverlayVisible(isVisible)
    }

    func beginOverlayRepositioning() {
        guard isRunning else { return }
        runtime.beginOverlayRepositioning()
    }

    func endOverlayRepositioning() {
        guard isRunning else { return }
        runtime.endOverlayRepositioning()
    }

    func resetOverlayPosition() {
        guard isRunning else { return }
        runtime.resetOverlayPosition()
    }

    func selectOverlayDisplay(_ selection: OverlayDisplaySelection) {
        runtime.selectOverlayDisplay(selection)
    }

    func startTranscriptionTest() {
        startRuntime(kind: .transcription)
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
        clearError()
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
                present(error)
                status = "Sound test needs attention"
                await finishActiveMode(statusAfterStop: nil)
            }
        }
    }

    func stopSoundTest() {
        guard activeMode == .soundTest else { return }
        stopActiveMode(statusAfterStop: "Sound test stopped")
    }

    private func startRuntime(
        kind: SessionKind,
        translationSelection: ResolvedProviderSelection? = nil,
        settingsArePersisted: Bool = false
    ) {
        guard activeMode == .idle, startTask == nil else { return }

        let viewMode: ActiveMode = kind == .translation ? .translation : .transcriptionTest
        let sessionID = UUID()
        let startingStatus = kind == .translation ? "Starting translation" : "Starting transcription test"
        activeSessionID = sessionID
        activeMode = viewMode
        status = settingsArePersisted ? startingStatus : "Saving settings"
        clearError()
        lastWarning = nil
        transcriptionEntries = []
        performanceDiagnostics = PipelinePerformanceDiagnostics()
        whisperDiagnostics = WhisperDiagnostics(
            modelState: .loading,
            modelID: settings.whisperModel
        )

        startTask = Task {
            defer { clearStartTask(for: sessionID) }

            if !settingsArePersisted {
                guard await save() else {
                    guard isCurrentSession(sessionID, mode: viewMode) else { return }
                    await finishActiveMode(statusAfterStop: "Settings need attention")
                    return
                }
            }
            guard isCurrentSession(sessionID, mode: viewMode) else { return }
            status = startingStatus

            let started = await runtime.start(
                kind: kind,
                translationSelection: translationSelection,
                handlers: SessionRuntimeHandlers(
                    onError: { [weak self, sessionID] error in
                        guard self?.activeSessionID == sessionID else { return }
                        self?.present(error)
                        self?.status = "Needs attention"
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
                    },
                    onPerformanceDiagnostics: { [weak self, sessionID] diagnostics in
                        await MainActor.run {
                            guard self?.activeSessionID == sessionID else { return }
                            self?.performanceDiagnostics = diagnostics
                        }
                    },
                    onEnded: { [weak self, sessionID] reason in
                        guard self?.activeSessionID == sessionID else { return }
                        self?.activeMode = .idle
                        self?.activeTranslationProviderKind = nil
                        self?.activeTranslationProviderEndpoint = nil
                        self?.errorRecoveryActions.removeAll { $0 == .stopTranslation }
                        self?.status = reason == .failed ? "Needs attention" : "Stopped"
                    }
                )
            )
            guard isCurrentSession(sessionID, mode: viewMode) else { return }
            guard started else {
                await finishActiveMode(statusAfterStop: "Needs attention")
                return
            }
            status = kind == .translation ? "Listening" : "Testing transcription"
        }
    }

    private func stopActiveMode(statusAfterStop: String) {
        Task {
            await finishActiveMode(statusAfterStop: statusAfterStop)
        }
    }

    private func finishActiveMode(statusAfterStop: String?) async {
        let mode = activeMode
        let finishingSessionID = activeSessionID
        let pendingStartTask = startTask
        startTask = nil
        pendingStartTask?.cancel()

        if mode == .soundTest {
            await soundTestEngine?.stop()
            soundDiagnosticsTask?.cancel()
            soundDiagnosticsTask = nil
            soundTestEngine = nil
        } else if mode == .translation || mode == .transcriptionTest {
            await runtime.stop(reason: .cancelled)
        }

        guard activeSessionID == finishingSessionID else { return }
        activeSessionID = UUID()
        activeMode = .idle
        activeTranslationProviderKind = nil
        activeTranslationProviderEndpoint = nil
        errorRecoveryActions.removeAll { $0 == .stopTranslation }

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

    private func applyCommittedSettings(_ snapshot: SettingsEditorSnapshot) {
        settings = snapshot.appSettings
        whisperDiagnostics.modelID = snapshot.appSettings.whisperModel
        if let credentialStore {
            let storedAPIKey = (try? credentialStore.loadCredential(
                for: ProviderDefaults.openAICredentialID
            )) ?? nil
            apiKey = storedAPIKey ?? ""
            credentialState = apiKey.isEmpty ? .notStored : .stored
        }
        status = "Settings saved"
        clearError()
        Task { @MainActor [weak self] in
            await self?.refreshTranslationDestinationDescription()
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

    private func present(_ error: any Error) {
        if let error = error as? MLingoError {
            present(error)
        } else {
            presentMessage(error.localizedDescription)
        }
    }

    private func present(_ error: MLingoError) {
        let presentation = AppIssuePresentation(
            error: error,
            isTranslationActive: isTranslationSession,
            translationProviderKind: activeTranslationProviderKind,
            translationProviderEndpoint: activeTranslationProviderEndpoint
        )
        lastError = presentation.message
        errorRecoveryActions = presentation.actions
    }

    private func presentMessage(
        _ message: String,
        actions: [AppRecoveryAction] = [.dismiss]
    ) {
        lastError = message
        errorRecoveryActions = actions
    }

    private func clearError() {
        lastError = nil
        errorRecoveryActions = []
    }
}

struct OpenAISettingsValidation: Equatable {
    let apiKeyError: String?
    let modelError: String?
    let sourceLanguageError: String?
    let targetLanguageError: String?
    let normalizedSettings: AppSettings

    init(apiKey: String, settings: AppSettings) {
        let validation = AppSettingsValidation(settings: settings)
        apiKeyError = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Enter an OpenAI Platform API key."
            : nil
        modelError = validation.errors[.openAIModel]
        sourceLanguageError = validation.errors[.sourceLanguage]
        targetLanguageError = validation.errors[.targetLanguage]
        normalizedSettings = validation.normalizedSettings
    }

    var isValid: Bool {
        apiKeyError == nil && hasValidTranslationSettings
    }

    var hasValidTranslationSettings: Bool {
        modelError == nil
            && sourceLanguageError == nil
            && targetLanguageError == nil
    }

    var firstError: String? {
        apiKeyError
            ?? modelError
            ?? sourceLanguageError
            ?? targetLanguageError
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
