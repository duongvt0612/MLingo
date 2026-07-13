import Foundation

@MainActor
public final class SubtitlePipeline {
    private let audioEngine: AudioEngineProtocol
    private let whisperEngine: WhisperEngineProtocol
    private let translationEngine: TranslationEngineProtocol
    private let overlayEngine: OverlayEngineProtocol
    private let settingsStore: SettingsStoreProtocol

    private var task: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
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

    public func start(
        onError: @escaping @Sendable (String) -> Void,
        onAudioDiagnostics: (@Sendable (AudioCaptureDiagnostics) -> Void)? = nil
    ) async {
        MLingoLogger.pipeline.info("Starting subtitle pipeline")
        await stop()

        do {
            let settings = try await settingsStore.load()
            try await whisperEngine.loadModel(named: settings.whisperModel)
            try await audioEngine.start()
            overlayEngine.show()
            MLingoLogger.pipeline.info("Subtitle pipeline started")

            if let onAudioDiagnostics {
                diagnosticsTask = Task { [audioEngine] in
                    for await diagnostics in audioEngine.diagnostics {
                        if Task.isCancelled { return }
                        onAudioDiagnostics(diagnostics)
                    }
                }
            }

            task = Task { [audioEngine, whisperEngine, translationEngine, settingsStore, overlayEngine] in
                var queue = OrderedSubtitleQueue()
                for await chunk in audioEngine.chunks {
                    if Task.isCancelled {
                        MLingoLogger.pipeline.debug("Subtitle pipeline task cancelled")
                        return
                    }

                    do {
                        let settings = try await settingsStore.load()
                        guard let transcript = try await whisperEngine.transcribe(
                            chunk,
                            language: settings.sourceLanguage
                        ) else {
                            continue
                        }

                        let subtitle = try await translationEngine.translate(transcript, settings: settings)
                        let ready = queue.insert(subtitle)

                        for item in ready {
                            overlayEngine.update(with: item, settings: settings)
                        }
                    } catch {
                        MLingoLogger.pipeline.error("Subtitle pipeline iteration failed: \(error.localizedDescription, privacy: .public)")
                        onError(error.localizedDescription)
                    }
                }
            }
        } catch {
            MLingoLogger.pipeline.error("Subtitle pipeline failed to start: \(error.localizedDescription, privacy: .public)")
            onError(error.localizedDescription)
        }
    }

    public func stop() async {
        MLingoLogger.pipeline.info("Stopping subtitle pipeline")
        task?.cancel()
        task = nil
        await audioEngine.stop()
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        queue = OrderedSubtitleQueue()
        overlayEngine.hide()
        MLingoLogger.pipeline.info("Subtitle pipeline stopped")
    }
}
