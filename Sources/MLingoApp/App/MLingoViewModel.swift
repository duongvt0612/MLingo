import Foundation
import MLingoCore
import Observation

@MainActor
@Observable
final class MLingoViewModel {
    var settings: AppSettings
    var apiKey: String = ""
    var isRunning = false
    var isTestingSound = false
    var status = "Ready"
    var lastError: String?
    var audioDiagnostics = AudioCaptureDiagnostics()

    private let settingsStore: SettingsStoreProtocol
    private let apiKeyStore: APIKeyStoreProtocol
    private let pipeline: SubtitlePipeline
    private var translationStartTask: Task<Void, Never>?
    private var translationSessionID = UUID()
    private var soundTestEngine: (any AudioEngineProtocol)?
    private var soundTestStartTask: Task<Void, Never>?
    private var soundTestSessionID = UUID()
    private var soundTestTask: Task<Void, Never>?

    init(
        settings: AppSettings,
        settingsStore: SettingsStoreProtocol,
        apiKeyStore: APIKeyStoreProtocol,
        pipeline: SubtitlePipeline
    ) {
        self.settings = settings
        self.settingsStore = settingsStore
        self.apiKeyStore = apiKeyStore
        self.pipeline = pipeline
    }

    static func live() -> MLingoViewModel {
        let settingsStore = UserDefaultsSettingsStore()
        let apiKeyStore = KeychainAPIKeyStore()
        let overlay = FloatingSubtitleWindowController()
        let translation = OpenAITranslationEngine(apiKeyStore: apiKeyStore)
        let pipeline = SubtitlePipeline(
            audioEngine: ScreenCaptureAudioEngine(),
            whisperEngine: MLXWhisperEngine(),
            translationEngine: translation,
            overlayEngine: overlay,
            settingsStore: settingsStore
        )

        return MLingoViewModel(
            settings: AppSettings(),
            settingsStore: settingsStore,
            apiKeyStore: apiKeyStore,
            pipeline: pipeline
        )
    }

    func load() async {
        do {
            settings = try await settingsStore.load()
            apiKey = try apiKeyStore.loadAPIKey() ?? ""
        } catch {
            lastError = error.localizedDescription
        }
    }

    func save() async {
        do {
            try await settingsStore.save(settings)
            if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try apiKeyStore.deleteAPIKey()
            } else {
                try apiKeyStore.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            status = "Settings saved"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func start() {
        guard !isRunning, translationStartTask == nil else { return }

        let sessionID = UUID()
        translationSessionID = sessionID
        translationStartTask = Task {
            defer {
                if translationSessionID == sessionID {
                    translationStartTask = nil
                }
            }

            await stopSoundTestSession(statusAfterStop: nil)
            guard isCurrentTranslationSession(sessionID) else { return }

            isRunning = true
            status = "Starting translation"
            lastError = nil
            await save()
            guard isCurrentTranslationSession(sessionID) else { return }

            await pipeline.start(
                onError: { [weak self, sessionID] message in
                    Task { @MainActor in
                        guard self?.translationSessionID == sessionID else { return }
                        self?.lastError = message
                        self?.status = "Needs attention"
                    }
                },
                onAudioDiagnostics: { [weak self, sessionID] diagnostics in
                    Task { @MainActor in
                        guard self?.translationSessionID == sessionID else { return }
                        self?.audioDiagnostics = diagnostics
                    }
                }
            )
            guard isCurrentTranslationSession(sessionID) else { return }
            status = "Listening"
        }
    }

    func stop() {
        guard isRunning || translationStartTask != nil else { return }
        Task {
            await stopTranslationSession(statusAfterStop: "Stopped")
        }
    }

    func startSoundTest() {
        guard !isTestingSound, soundTestStartTask == nil else { return }

        let sessionID = UUID()
        soundTestSessionID = sessionID
        soundTestStartTask = Task {
            defer {
                if soundTestSessionID == sessionID {
                    soundTestStartTask = nil
                }
            }

            await stopTranslationSession(statusAfterStop: nil)
            guard isCurrentSoundTestSession(sessionID) else { return }

            let audioEngine = ScreenCaptureAudioEngine()
            soundTestEngine = audioEngine
            isTestingSound = true
            status = "Testing system audio"
            lastError = nil
            audioDiagnostics = AudioCaptureDiagnostics(state: .requestingPermission)

            soundTestTask = Task { [weak self, audioEngine, sessionID] in
                for await diagnostics in audioEngine.diagnostics {
                    Task { @MainActor in
                        guard self?.soundTestSessionID == sessionID else { return }
                        self?.audioDiagnostics = diagnostics
                    }
                    if Task.isCancelled { return }
                }
            }

            do {
                try await audioEngine.start()
                guard isCurrentSoundTestSession(sessionID) else {
                    await audioEngine.stop()
                    return
                }
                status = "Testing system audio"
            } catch {
                guard isCurrentSoundTestSession(sessionID) else { return }
                lastError = error.localizedDescription
                status = "Sound test needs attention"
                await cleanupSoundTestSession(statusAfterStop: nil)
            }
        }
    }

    func stopSoundTest() {
        guard isTestingSound || soundTestStartTask != nil else { return }

        Task {
            await stopSoundTestSession(statusAfterStop: "Sound test stopped")
        }
    }

    private func stopTranslationSession(statusAfterStop: String?) async {
        guard isRunning || translationStartTask != nil else { return }

        let startTask = translationStartTask
        translationStartTask = nil
        translationSessionID = UUID()
        startTask?.cancel()
        await startTask?.value
        await pipeline.stop()
        isRunning = false
        if let statusAfterStop {
            status = statusAfterStop
        }
    }

    private func stopSoundTestSession(statusAfterStop: String?) async {
        guard isTestingSound || soundTestStartTask != nil || soundTestEngine != nil || soundTestTask != nil else { return }

        let startTask = soundTestStartTask
        soundTestStartTask = nil
        soundTestSessionID = UUID()
        startTask?.cancel()
        await startTask?.value
        await cleanupSoundTestSession(statusAfterStop: statusAfterStop)
    }

    private func cleanupSoundTestSession(statusAfterStop: String?) async {
        await soundTestEngine?.stop()
        soundTestTask?.cancel()
        soundTestTask = nil
        soundTestEngine = nil
        isTestingSound = false
        if let statusAfterStop {
            status = statusAfterStop
        }
    }

    private func isCurrentTranslationSession(_ sessionID: UUID) -> Bool {
        translationSessionID == sessionID && !Task.isCancelled
    }

    private func isCurrentSoundTestSession(_ sessionID: UUID) -> Bool {
        soundTestSessionID == sessionID && !Task.isCancelled
    }
}
