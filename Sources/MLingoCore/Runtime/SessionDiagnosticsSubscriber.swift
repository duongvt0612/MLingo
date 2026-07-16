struct SessionDiagnosticsSubscriber: Sendable {
    private let onAudioDiagnostics: @Sendable (AudioCaptureDiagnostics) async -> Void
    private let onWhisperDiagnostics: @Sendable (WhisperDiagnostics) async -> Void
    private let onPerformanceDiagnostics:
        @Sendable (PipelinePerformanceDiagnostics) async -> Void

    init(
        onAudioDiagnostics: @escaping @Sendable (AudioCaptureDiagnostics) async -> Void,
        onWhisperDiagnostics: @escaping @Sendable (WhisperDiagnostics) async -> Void,
        onPerformanceDiagnostics: @escaping @Sendable (
            PipelinePerformanceDiagnostics
        ) async -> Void
    ) {
        self.onAudioDiagnostics = onAudioDiagnostics
        self.onWhisperDiagnostics = onWhisperDiagnostics
        self.onPerformanceDiagnostics = onPerformanceDiagnostics
    }

    func receiveAudio(_ diagnostics: AudioCaptureDiagnostics) async {
        await onAudioDiagnostics(diagnostics)
    }

    func receiveWhisper(_ diagnostics: WhisperDiagnostics) async {
        await onWhisperDiagnostics(diagnostics)
    }

    func receivePerformance(_ diagnostics: PipelinePerformanceDiagnostics) async {
        await onPerformanceDiagnostics(diagnostics)
    }
}
