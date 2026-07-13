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
    private var soundTestEngine: (any AudioEngineProtocol)?
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
        guard !isRunning else { return }

        Task {
            await stopSoundTestSession(statusAfterStop: nil)

            isRunning = true
            status = "Starting translation"
            lastError = nil
            await save()
            await pipeline.start(
                onError: { [weak self] message in
                    Task { @MainActor in
                        self?.lastError = message
                        self?.status = "Needs attention"
                    }
                },
                onAudioDiagnostics: { [weak self] diagnostics in
                    Task { @MainActor in
                        self?.audioDiagnostics = diagnostics
                    }
                }
            )
            status = "Listening"
        }
    }

    func stop() {
        guard isRunning else { return }
        Task {
            await stopTranslationSession(statusAfterStop: "Stopped")
        }
    }

    func startSoundTest() {
        guard !isTestingSound else { return }

        Task {
            await stopTranslationSession(statusAfterStop: nil)

            let audioEngine = ScreenCaptureAudioEngine()
            soundTestEngine = audioEngine
            isTestingSound = true
            status = "Testing system audio"
            lastError = nil
            audioDiagnostics = AudioCaptureDiagnostics(state: .requestingPermission)

            soundTestTask = Task { [weak self, audioEngine] in
                for await diagnostics in audioEngine.diagnostics {
                    Task { @MainActor in
                        self?.audioDiagnostics = diagnostics
                    }
                    if Task.isCancelled { return }
                }
            }

            do {
                try await audioEngine.start()
                status = "Testing system audio"
            } catch {
                lastError = error.localizedDescription
                status = "Sound test needs attention"
                await stopSoundTestSession(statusAfterStop: nil)
            }
        }
    }

    func stopSoundTest() {
        guard isTestingSound else { return }

        Task {
            await stopSoundTestSession(statusAfterStop: "Sound test stopped")
        }
    }

    private func stopTranslationSession(statusAfterStop: String?) async {
        guard isRunning else { return }

        await pipeline.stop()
        isRunning = false
        if let statusAfterStop {
            status = statusAfterStop
        }
    }

    private func stopSoundTestSession(statusAfterStop: String?) async {
        guard isTestingSound || soundTestEngine != nil || soundTestTask != nil else { return }

        await soundTestEngine?.stop()
        soundTestTask?.cancel()
        soundTestTask = nil
        soundTestEngine = nil
        isTestingSound = false
        if let statusAfterStop {
            status = statusAfterStop
        }
    }
}
