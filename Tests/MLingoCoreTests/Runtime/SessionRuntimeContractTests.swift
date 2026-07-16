import Foundation
import Testing
@testable import MLingoCore

@Test @MainActor
func sessionRuntimeContractCarriesHandlersAndCommands() async {
    let callbackRecorder = RuntimeCallbackRecorder()
    let expectedError = MLingoError.noAudioSource
    let expectedAudioDiagnostics = AudioCaptureDiagnostics(capturedChunkCount: 3)
    let expectedTranscript = Transcript(text: "Contract transcript", timestamp: 4)
    let expectedWhisperDiagnostics = WhisperDiagnostics(
        modelState: .ready,
        modelID: "contract-model"
    )
    let expectedPerformanceDiagnostics = PipelinePerformanceDiagnostics(
        sessionDuration: 5
    )
    let handlers = SessionRuntimeHandlers(
        onError: { callbackRecorder.append(error: $0) },
        onWarning: { callbackRecorder.append(warning: $0) },
        onAudioDiagnostics: { callbackRecorder.append(audio: $0) },
        onTranscript: { callbackRecorder.append(transcript: $0) },
        onWhisperDiagnostics: { callbackRecorder.append(whisper: $0) },
        onPerformanceDiagnostics: { callbackRecorder.append(performance: $0) },
        onEnded: { callbackRecorder.append(endReason: $0) }
    )
    let runtime = RuntimeContractSpy()

    let started = await runtime.start(
        kind: .translation,
        translationSelection: nil,
        handlers: handlers
    )
    #expect(runtime.receivedHandlers != nil)
    guard let receivedHandlers = runtime.receivedHandlers else { return }
    receivedHandlers.onError(expectedError)
    receivedHandlers.onWarning("Contract warning")
    await receivedHandlers.onAudioDiagnostics(expectedAudioDiagnostics)
    await receivedHandlers.onTranscript(expectedTranscript)
    await receivedHandlers.onWhisperDiagnostics(expectedWhisperDiagnostics)
    await receivedHandlers.onPerformanceDiagnostics(expectedPerformanceDiagnostics)
    receivedHandlers.onEnded(.failed)
    await runtime.stop(reason: .cancelled)
    runtime.setOverlayVisible(false)
    runtime.beginOverlayRepositioning()
    runtime.endOverlayRepositioning()
    runtime.resetOverlayPosition()
    runtime.selectOverlayDisplay(.automatic)

    #expect(started)
    #expect(runtime.startedKinds == [.translation])
    #expect(runtime.receivedHandlers != nil)
    #expect(runtime.stopReasons == [.cancelled])
    #expect(runtime.overlayCommandCount == 5)
    #expect(callbackRecorder.errors == [expectedError])
    #expect(callbackRecorder.warnings == ["Contract warning"])
    #expect(callbackRecorder.audioDiagnostics == [expectedAudioDiagnostics])
    #expect(callbackRecorder.transcripts == [expectedTranscript])
    #expect(callbackRecorder.whisperDiagnostics == [expectedWhisperDiagnostics])
    #expect(callbackRecorder.performanceDiagnostics == [expectedPerformanceDiagnostics])
    #expect(callbackRecorder.endReasons == [.failed])
}

@MainActor
private final class RuntimeContractSpy: SessionRuntimeProtocol {
    var overlayPresentationState = OverlayPresentationState()
    var startedKinds: [SessionKind] = []
    var stopReasons: [SessionEndReason] = []
    var overlayCommandCount = 0
    var receivedHandlers: SessionRuntimeHandlers?

    func start(
        kind: SessionKind,
        translationSelection: ResolvedProviderSelection?,
        handlers: SessionRuntimeHandlers
    ) async -> Bool {
        startedKinds.append(kind)
        receivedHandlers = handlers
        return true
    }

    func stop(reason: SessionEndReason) async {
        stopReasons.append(reason)
    }

    func setOverlayVisible(_ isVisible: Bool) { overlayCommandCount += 1 }
    func beginOverlayRepositioning() { overlayCommandCount += 1 }
    func endOverlayRepositioning() { overlayCommandCount += 1 }
    func resetOverlayPosition() { overlayCommandCount += 1 }
    func selectOverlayDisplay(_ selection: OverlayDisplaySelection) { overlayCommandCount += 1 }
}

private final class RuntimeCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedErrors: [MLingoError] = []
    private var recordedWarnings: [String] = []
    private var recordedAudioDiagnostics: [AudioCaptureDiagnostics] = []
    private var recordedTranscripts: [Transcript] = []
    private var recordedWhisperDiagnostics: [WhisperDiagnostics] = []
    private var recordedPerformanceDiagnostics: [PipelinePerformanceDiagnostics] = []
    private var recordedEndReasons: [SessionEndReason] = []

    var errors: [MLingoError] { lock.withLock { recordedErrors } }
    var warnings: [String] { lock.withLock { recordedWarnings } }
    var audioDiagnostics: [AudioCaptureDiagnostics] { lock.withLock { recordedAudioDiagnostics } }
    var transcripts: [Transcript] { lock.withLock { recordedTranscripts } }
    var whisperDiagnostics: [WhisperDiagnostics] { lock.withLock { recordedWhisperDiagnostics } }
    var performanceDiagnostics: [PipelinePerformanceDiagnostics] {
        lock.withLock { recordedPerformanceDiagnostics }
    }
    var endReasons: [SessionEndReason] { lock.withLock { recordedEndReasons } }

    func append(error: MLingoError) { lock.withLock { recordedErrors.append(error) } }
    func append(warning: String) { lock.withLock { recordedWarnings.append(warning) } }
    func append(audio: AudioCaptureDiagnostics) {
        lock.withLock { recordedAudioDiagnostics.append(audio) }
    }
    func append(transcript: Transcript) { lock.withLock { recordedTranscripts.append(transcript) } }
    func append(whisper: WhisperDiagnostics) {
        lock.withLock { recordedWhisperDiagnostics.append(whisper) }
    }
    func append(performance: PipelinePerformanceDiagnostics) {
        lock.withLock { recordedPerformanceDiagnostics.append(performance) }
    }
    func append(endReason: SessionEndReason) {
        lock.withLock { recordedEndReasons.append(endReason) }
    }
}
