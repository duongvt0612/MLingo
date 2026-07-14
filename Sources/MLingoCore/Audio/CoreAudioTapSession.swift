import CoreAudio
import Foundation

enum CoreAudioHALOperation: String, CaseIterable, Sendable {
    case createProcessTap
    case createAggregateDevice
    case createIOProc
    case startDevice
    case stopDevice
    case destroyIOProc
    case destroyAggregateDevice
    case destroyProcessTap
}

struct CoreAudioIOProcToken: Hashable, Sendable {
    let rawValue: UInt64
}

typealias CoreAudioInputHandler = @Sendable (
    _ samples: [Float],
    _ sampleRate: Double,
    _ timestamp: TimeInterval
) -> Void

protocol CoreAudioHALProtocol: Sendable {
    func createProcessTap() throws -> AudioObjectID
    func createAggregateDevice(for tapID: AudioObjectID) throws -> AudioObjectID
    func createIOProc(
        on deviceID: AudioObjectID,
        handler: @escaping CoreAudioInputHandler
    ) throws -> CoreAudioIOProcToken
    func startDevice(_ deviceID: AudioObjectID, ioProc: CoreAudioIOProcToken) throws
    func stopDevice(_ deviceID: AudioObjectID, ioProc: CoreAudioIOProcToken)
    func destroyIOProc(_ ioProc: CoreAudioIOProcToken, on deviceID: AudioObjectID)
    func destroyAggregateDevice(_ deviceID: AudioObjectID)
    func destroyProcessTap(_ tapID: AudioObjectID)
}

final class CoreAudioTapSession: @unchecked Sendable {
    private let hal: any CoreAudioHALProtocol
    private let lock = NSRecursiveLock()
    private var tapID: AudioObjectID?
    private var aggregateDeviceID: AudioObjectID?
    private var ioProc: CoreAudioIOProcToken?
    private var deviceStarted = false

    init(hal: any CoreAudioHALProtocol) {
        self.hal = hal
    }

    func start(handler: @escaping CoreAudioInputHandler) throws {
        try lock.withLock {
            cleanupLocked()
            do {
                let tapID = try hal.createProcessTap()
                self.tapID = tapID

                let aggregateDeviceID = try hal.createAggregateDevice(for: tapID)
                self.aggregateDeviceID = aggregateDeviceID

                let ioProc = try hal.createIOProc(on: aggregateDeviceID, handler: handler)
                self.ioProc = ioProc

                try hal.startDevice(aggregateDeviceID, ioProc: ioProc)
                deviceStarted = true
            } catch {
                cleanupLocked()
                throw error
            }
        }
    }

    func stop() {
        lock.withLock {
            cleanupLocked()
        }
    }

    private func cleanupLocked() {
        if deviceStarted, let aggregateDeviceID, let ioProc {
            hal.stopDevice(aggregateDeviceID, ioProc: ioProc)
        }
        deviceStarted = false

        if let ioProc, let aggregateDeviceID {
            hal.destroyIOProc(ioProc, on: aggregateDeviceID)
        }
        self.ioProc = nil

        if let aggregateDeviceID {
            hal.destroyAggregateDevice(aggregateDeviceID)
        }
        self.aggregateDeviceID = nil

        if let tapID {
            hal.destroyProcessTap(tapID)
        }
        self.tapID = nil
    }
}
