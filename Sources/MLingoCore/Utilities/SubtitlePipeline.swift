import Foundation

@MainActor
public final class SubtitlePipeline {
    private let audioEngine: AudioEngineProtocol
    private let whisperEngine: WhisperEngineProtocol
    private let translationEngine: TranslationEngineProtocol
    private let overlayEngine: OverlayEngineProtocol
    private let settingsStore: SettingsStoreProtocol

    private var task: Task<Void, Never>?
    private var queue = OrderedSubtitleQueue()

    public init(
        audioEngine: AudioEngineProtocol,
        whisperEngine: WhisperEngineProtocol,
        translationEngine: TranslationEngineProtocol,
        overlayEngine: OverlayEngineProtocol,
        settingsStore: SettingsStoreProtocol
    ) {
        self.audioEngine = audioEngine
        self.whisperEngine = whisperEngine
        self.translationEngine = translationEngine
        self.overlayEngine = overlayEngine
        self.settingsStore = settingsStore
    }

    public func start(onError: @escaping @Sendable (String) -> Void) async {
        await stop()

        do {
            let settings = try await settingsStore.load()
            try await whisperEngine.loadModel(named: settings.whisperModel)
            try await audioEngine.start()
            await overlayEngine.show()

            task = Task { [audioEngine, whisperEngine, translationEngine, settingsStore, overlayEngine] in
                var queue = OrderedSubtitleQueue()
                for await chunk in audioEngine.chunks {
                    if Task.isCancelled { return }

                    do {
                        let settings = try await settingsStore.load()
                        guard let transcript = try await whisperEngine.transcribe(chunk) else {
                            continue
                        }

                        let subtitle = try await translationEngine.translate(transcript, settings: settings)
                        let ready = queue.insert(subtitle)

                        for item in ready {
                            await overlayEngine.update(with: item, settings: settings)
                        }
                    } catch {
                        onError(error.localizedDescription)
                    }
                }
            }
        } catch {
            onError(error.localizedDescription)
        }
    }

    public func stop() async {
        task?.cancel()
        task = nil
        queue = OrderedSubtitleQueue()
        await audioEngine.stop()
        await overlayEngine.hide()
    }
}
