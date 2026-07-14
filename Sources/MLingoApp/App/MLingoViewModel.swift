import Foundation
import MLingoCore
import Observation

@MainActor
@Observable
final class MLingoViewModel {
    enum ActiveMode: Equatable {
        case idle
        case soundTest
        case transcriptionTest
        case translation
    }

    var settings: AppSettings
    var apiKey: String = ""
    private(set) var activeMode: ActiveMode = .idle
    var status = "Ready"
    var lastError: String?
    private(set) var transcriptionEntries: [TranscriptLogEntry] = []
    var audioDiagnostics = AudioCaptureDiagnostics()
    var whisperDiagnostics = WhisperDiagnostics()

    var isRunning: Bool { activeMode == .translation }
    var isTestingSound: Bool { activeMode == .soundTest }
    var isTestingTranscription: Bool { activeMode == .transcriptionTest }
    var isActive: Bool { activeMode != .idle }

    private let settingsStore: SettingsStoreProtocol
    private let apiKeyStore: APIKeyStoreProtocol
    private let pipeline: SubtitlePipeline
    private var startTask: Task<Void, Never>?
    private var activeSessionID = UUID()
    private var soundTestEngine: (any AudioEngineProtocol)?
    private var soundDiagnosticsTask: Task<Void, Never>?

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
        whisperDiagnostics.modelID = settings.whisperModel
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
            whisperDiagnostics.modelID = settings.whisperModel
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
        startPipeline(mode: .translation)
    }

    func stop() {
        guard activeMode == .translation else { return }
        stopActiveMode(statusAfterStop: "Stopped")
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
        audioDiagnostics = AudioCaptureDiagnostics(state: .requestingPermission)

        startTask = Task {
            defer { clearStartTask(for: sessionID) }

            let audioEngine = ScreenCaptureAudioEngine()
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
        status = startingStatus
        lastError = nil
        transcriptionEntries = []
        whisperDiagnostics = WhisperDiagnostics(
            modelState: .loading,
            modelID: settings.whisperModel
        )

        startTask = Task {
            defer { clearStartTask(for: sessionID) }

            await save()
            guard isCurrentSession(sessionID, mode: viewMode) else { return }
            status = startingStatus

            await pipeline.start(
                mode: mode,
                onError: { [weak self, sessionID] message in
                    Task { @MainActor in
                        guard self?.activeSessionID == sessionID else { return }
                        self?.lastError = message
                        self?.status = "Needs attention"
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
}
