import CoreAudio
import Foundation
import Testing
@testable import MLingoCore

@Test
func systemAudioFactoryHonorsPreferredBackendWhenAvailable() {
    let coreAudio = FactoryAudioEngine()
    let screenCaptureKit = FactoryAudioEngine()

    let modernFactory = SystemAudioEngineFactory(
        isCoreAudioTapAvailable: true,
        makeCoreAudioTapEngine: { coreAudio },
        makeScreenCaptureKitEngine: { screenCaptureKit }
    )
    let legacyFactory = SystemAudioEngineFactory(
        isCoreAudioTapAvailable: false,
        makeCoreAudioTapEngine: { coreAudio },
        makeScreenCaptureKitEngine: { screenCaptureKit }
    )

    #expect(modernFactory.makeAudioEngine(preferredBackend: .coreAudioTap) === coreAudio)
    #expect(modernFactory.makeAudioEngine(preferredBackend: .screenCaptureKit) === screenCaptureKit)
    #expect(legacyFactory.makeAudioEngine(preferredBackend: .coreAudioTap) === screenCaptureKit)
}

@Test
func modernFactoryDoesNotFallbackAfterCoreAudioPermissionFailure() async {
    let providers = AudioEngineProviderRecorder()
    let factory = SystemAudioEngineFactory(
        isCoreAudioTapAvailable: true,
        makeCoreAudioTapEngine: {
            providers.recordCoreAudioCreation()
            return FactoryAudioEngine(
                startError: MLingoError.systemAudioPermissionDenied
            )
        },
        makeScreenCaptureKitEngine: {
            providers.recordScreenCaptureKitCreation()
            return FactoryAudioEngine()
        }
    )

    let engine = factory.makeAudioEngine(preferredBackend: .coreAudioTap)
    do {
        try await engine.start()
        Issue.record("Expected Core Audio permission denial")
    } catch {
        #expect(error as? MLingoError == .systemAudioPermissionDenied)
    }

    #expect(providers.coreAudioCreationCount == 1)
    #expect(providers.screenCaptureKitCreationCount == 0)
}

@Test(arguments: [
    CoreAudioHALOperation.createProcessTap,
    .createAggregateDevice,
    .createIOProc,
    .startDevice,
])
func coreAudioTapSessionCleansUpPartialStarts(failingAt failure: CoreAudioHALOperation) {
    let hal = FakeCoreAudioHAL(failingAt: failure)
    let session = CoreAudioTapSession(hal: hal)

    #expect(throws: (any Error).self) {
        try session.start { _, _, _ in }
    }

    #expect(hal.operations == expectedOperations(for: failure))
    session.stop()
    #expect(hal.operations == expectedOperations(for: failure))
}

@Test
func coreAudioTapSessionStopsInReverseCreationOrder() throws {
    let hal = FakeCoreAudioHAL()
    let session = CoreAudioTapSession(hal: hal)

    try session.start { _, _, _ in }
    session.stop()
    session.stop()

    #expect(hal.operations == [
        .createProcessTap,
        .createAggregateDevice,
        .createIOProc,
        .startDevice,
        .stopDevice,
        .destroyIOProc,
        .destroyAggregateDevice,
        .destroyProcessTap,
    ])
}

private func expectedOperations(for failure: CoreAudioHALOperation) -> [CoreAudioHALOperation] {
    switch failure {
    case .createProcessTap:
        [.createProcessTap]
    case .createAggregateDevice:
        [.createProcessTap, .createAggregateDevice, .destroyProcessTap]
    case .createIOProc:
        [
            .createProcessTap,
            .createAggregateDevice,
            .createIOProc,
            .destroyAggregateDevice,
            .destroyProcessTap,
        ]
    case .startDevice:
        [
            .createProcessTap,
            .createAggregateDevice,
            .createIOProc,
            .startDevice,
            .destroyIOProc,
            .destroyAggregateDevice,
            .destroyProcessTap,
        ]
    default:
        []
    }
}

private final class FakeCoreAudioHAL: CoreAudioHALProtocol, @unchecked Sendable {
    private(set) var operations: [CoreAudioHALOperation] = []
    private let failingOperation: CoreAudioHALOperation?

    init(failingAt operation: CoreAudioHALOperation? = nil) {
        failingOperation = operation
    }

    func createProcessTap() throws -> AudioObjectID {
        try perform(.createProcessTap)
        return 11
    }

    func createAggregateDevice(for tapID: AudioObjectID) throws -> AudioObjectID {
        try perform(.createAggregateDevice)
        return 22
    }

    func createIOProc(
        on deviceID: AudioObjectID,
        handler: @escaping CoreAudioInputHandler
    ) throws -> CoreAudioIOProcToken {
        try perform(.createIOProc)
        return CoreAudioIOProcToken(rawValue: 33)
    }

    func startDevice(_ deviceID: AudioObjectID, ioProc: CoreAudioIOProcToken) throws {
        try perform(.startDevice)
    }

    func stopDevice(_ deviceID: AudioObjectID, ioProc: CoreAudioIOProcToken) {
        operations.append(.stopDevice)
    }

    func destroyIOProc(_ ioProc: CoreAudioIOProcToken, on deviceID: AudioObjectID) {
        operations.append(.destroyIOProc)
    }

    func destroyAggregateDevice(_ deviceID: AudioObjectID) {
        operations.append(.destroyAggregateDevice)
    }

    func destroyProcessTap(_ tapID: AudioObjectID) {
        operations.append(.destroyProcessTap)
    }

    private func perform(_ operation: CoreAudioHALOperation) throws {
        operations.append(operation)
        if operation == failingOperation {
            throw MLingoError.coreAudioHALFailure(operation: operation.rawValue, status: -1)
        }
    }
}

private final class FactoryAudioEngine: AudioEngineProtocol, @unchecked Sendable {
    let chunks: AsyncStream<AudioChunk>
    let diagnostics: AsyncStream<AudioCaptureDiagnostics>
    private let startError: (any Error)?

    init(startError: (any Error)? = nil) {
        chunks = AsyncStream { _ in }
        diagnostics = AsyncStream { _ in }
        self.startError = startError
    }

    var state: AudioCaptureState { get async { .idle } }

    func start() async throws {
        if let startError { throw startError }
    }

    func stop() async {}
}

private final class AudioEngineProviderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var coreAudioCreations = 0
    private var screenCaptureKitCreations = 0

    var coreAudioCreationCount: Int { lock.withLock { coreAudioCreations } }
    var screenCaptureKitCreationCount: Int { lock.withLock { screenCaptureKitCreations } }

    func recordCoreAudioCreation() {
        lock.withLock { coreAudioCreations += 1 }
    }

    func recordScreenCaptureKitCreation() {
        lock.withLock { screenCaptureKitCreations += 1 }
    }
}
