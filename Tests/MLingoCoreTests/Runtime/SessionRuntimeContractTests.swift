import Foundation
import Testing
@testable import MLingoCore

@Test @MainActor
func sessionRuntimeContractCarriesHandlersAndCommands() async {
    let handlers = SessionRuntimeHandlers(
        onError: { _ in },
        onWarning: { _ in },
        onAudioDiagnostics: { _ in },
        onTranscript: { _ in },
        onWhisperDiagnostics: { _ in },
        onPerformanceDiagnostics: { _ in }
    )
    let runtime = RuntimeContractSpy()

    let started = await runtime.start(
        kind: .translation,
        translationSelection: nil,
        handlers: handlers
    )
    await runtime.stop(reason: .cancelled)
    runtime.setOverlayVisible(false)
    runtime.beginOverlayRepositioning()
    runtime.endOverlayRepositioning()
    runtime.resetOverlayPosition()
    runtime.selectOverlayDisplay(.automatic)

    #expect(started)
    #expect(runtime.startedKinds == [.translation])
    #expect(runtime.stopReasons == [.cancelled])
    #expect(runtime.overlayCommandCount == 5)
}

@MainActor
private final class RuntimeContractSpy: SessionRuntimeProtocol {
    var overlayPresentationState = OverlayPresentationState()
    var startedKinds: [SessionKind] = []
    var stopReasons: [SessionEndReason] = []
    var overlayCommandCount = 0

    func start(
        kind: SessionKind,
        translationSelection: ResolvedProviderSelection?,
        handlers: SessionRuntimeHandlers
    ) async -> Bool {
        startedKinds.append(kind)
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
