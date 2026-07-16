public struct SessionRuntimeHandlers: Sendable {
    public let onError: @MainActor @Sendable (MLingoError) -> Void
    public let onWarning: @Sendable (String) -> Void
    public let onAudioDiagnostics: @Sendable (AudioCaptureDiagnostics) async -> Void
    public let onTranscript: @Sendable (Transcript) async -> Void
    public let onWhisperDiagnostics: @Sendable (WhisperDiagnostics) async -> Void
    public let onPerformanceDiagnostics:
        @Sendable (PipelinePerformanceDiagnostics) async -> Void

    public init(
        onError: @escaping @MainActor @Sendable (MLingoError) -> Void,
        onWarning: @escaping @Sendable (String) -> Void = { _ in },
        onAudioDiagnostics: @escaping @Sendable (AudioCaptureDiagnostics) async -> Void = { _ in },
        onTranscript: @escaping @Sendable (Transcript) async -> Void = { _ in },
        onWhisperDiagnostics: @escaping @Sendable (WhisperDiagnostics) async -> Void = { _ in },
        onPerformanceDiagnostics: @escaping @Sendable (
            PipelinePerformanceDiagnostics
        ) async -> Void = { _ in }
    ) {
        self.onError = onError
        self.onWarning = onWarning
        self.onAudioDiagnostics = onAudioDiagnostics
        self.onTranscript = onTranscript
        self.onWhisperDiagnostics = onWhisperDiagnostics
        self.onPerformanceDiagnostics = onPerformanceDiagnostics
    }
}

@MainActor
public protocol SessionRuntimeProtocol: AnyObject {
    var overlayPresentationState: OverlayPresentationState { get }

    @discardableResult
    func start(
        kind: SessionKind,
        translationSelection: ResolvedProviderSelection?,
        handlers: SessionRuntimeHandlers
    ) async -> Bool

    func stop(reason: SessionEndReason) async

    func setOverlayVisible(_ isVisible: Bool)
    func beginOverlayRepositioning()
    func endOverlayRepositioning()
    func resetOverlayPosition()
    func selectOverlayDisplay(_ selection: OverlayDisplaySelection)
}

public extension SessionRuntimeProtocol {
    func stop() async {
        await stop(reason: .cancelled)
    }
}
