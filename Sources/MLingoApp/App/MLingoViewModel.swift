import Foundation
import MLingoCore
import Observation

@MainActor
@Observable
final class MLingoViewModel {
    var settings: AppSettings
    var apiKey: String = ""
    var isRunning = false
    var status = "Ready"
    var lastError: String?

    private let settingsStore: SettingsStoreProtocol
    private let apiKeyStore: APIKeyStoreProtocol
    private let pipeline: SubtitlePipeline

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
        isRunning = true
        status = "Starting capture"
        lastError = nil

        Task {
            await save()
            await pipeline.start { [weak self] message in
                Task { @MainActor in
                    self?.lastError = message
                    self?.status = "Needs attention"
                }
            }
            status = "Listening"
        }
    }

    func stop() {
        guard isRunning else { return }
        Task {
            await pipeline.stop()
            isRunning = false
            status = "Stopped"
        }
    }
}
