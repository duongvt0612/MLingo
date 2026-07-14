import AudioToolbox
import CoreAudio
import Foundation

@available(macOS 14.2, *)
final class SystemCoreAudioHAL: CoreAudioHALProtocol, @unchecked Sendable {
    private struct IOProcRegistration {
        let deviceID: AudioObjectID
        let ioProcID: AudioDeviceIOProcID
    }

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(
        label: "com.duongvt.MLingo.core-audio-tap",
        qos: .userInitiated
    )
    private var tapUIDs: [AudioObjectID: String] = [:]
    private var tapFormats: [AudioObjectID: AudioStreamBasicDescription] = [:]
    private var deviceFormats: [AudioObjectID: AudioStreamBasicDescription] = [:]
    private var ioProcs: [UInt64: IOProcRegistration] = [:]
    private var nextIOProcToken: UInt64 = 1

    func createProcessTap() throws -> AudioObjectID {
        let excludedProcessIDs = currentProcessObjectID().map { [$0] } ?? []
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: excludedProcessIDs
        )
        description.name = "MLingo System Audio"
        description.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        try check(status, operation: .createProcessTap, permissionSensitive: true)

        do {
            let tapUID = try readTapUID(tapID)
            let format = try readTapFormat(tapID)
            lock.withLock {
                tapUIDs[tapID] = tapUID
                tapFormats[tapID] = format
            }
            return tapID
        } catch {
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    func createAggregateDevice(for tapID: AudioObjectID) throws -> AudioObjectID {
        let tapInfo = lock.withLock {
            (tapUIDs[tapID], tapFormats[tapID])
        }
        guard let tapUID = tapInfo.0, let tapFormat = tapInfo.1 else {
            throw MLingoError.coreAudioHALFailure(
                operation: CoreAudioHALOperation.createAggregateDevice.rawValue,
                status: kAudioHardwareBadObjectError
            )
        }

        let aggregateUID = "com.duongvt.MLingo.aggregate.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MLingo Private System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID]
            ],
        ]

        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(
            description as CFDictionary,
            &aggregateDeviceID
        )
        try check(status, operation: .createAggregateDevice)
        lock.withLock {
            deviceFormats[aggregateDeviceID] = tapFormat
        }
        return aggregateDeviceID
    }

    func createIOProc(
        on deviceID: AudioObjectID,
        handler: @escaping CoreAudioInputHandler
    ) throws -> CoreAudioIOProcToken {
        guard let format = lock.withLock({ deviceFormats[deviceID] }) else {
            throw MLingoError.coreAudioHALFailure(
                operation: CoreAudioHALOperation.createIOProc.rawValue,
                status: kAudioHardwareBadObjectError
            )
        }

        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            deviceID,
            ioQueue
        ) { _, inputData, inputTime, _, _ in
            guard
                let samples = AudioPCMNormalizer.downmix(
                    bufferList: inputData,
                    streamDescription: format
                ),
                !samples.isEmpty
            else {
                return
            }

            let timestamp = Self.timestamp(
                from: inputTime,
                sampleRate: format.mSampleRate
            )
            handler(samples, format.mSampleRate, timestamp)
        }
        try check(status, operation: .createIOProc)
        guard let ioProcID else {
            throw MLingoError.coreAudioHALFailure(
                operation: CoreAudioHALOperation.createIOProc.rawValue,
                status: kAudioHardwareUnspecifiedError
            )
        }

        return lock.withLock {
            let token = CoreAudioIOProcToken(rawValue: nextIOProcToken)
            nextIOProcToken += 1
            ioProcs[token.rawValue] = IOProcRegistration(
                deviceID: deviceID,
                ioProcID: ioProcID
            )
            return token
        }
    }

    func startDevice(_ deviceID: AudioObjectID, ioProc: CoreAudioIOProcToken) throws {
        guard let registration = registration(for: ioProc, deviceID: deviceID) else {
            throw MLingoError.coreAudioHALFailure(
                operation: CoreAudioHALOperation.startDevice.rawValue,
                status: kAudioHardwareBadObjectError
            )
        }
        try check(
            AudioDeviceStart(deviceID, registration.ioProcID),
            operation: .startDevice,
            permissionSensitive: true
        )
    }

    func stopDevice(_ deviceID: AudioObjectID, ioProc: CoreAudioIOProcToken) {
        guard let registration = registration(for: ioProc, deviceID: deviceID) else { return }
        logCleanupFailure(
            AudioDeviceStop(deviceID, registration.ioProcID),
            operation: .stopDevice
        )
    }

    func destroyIOProc(_ ioProc: CoreAudioIOProcToken, on deviceID: AudioObjectID) {
        let registration = lock.withLock {
            ioProcs.removeValue(forKey: ioProc.rawValue)
        }
        guard let registration, registration.deviceID == deviceID else { return }
        logCleanupFailure(
            AudioDeviceDestroyIOProcID(deviceID, registration.ioProcID),
            operation: .destroyIOProc
        )
    }

    func destroyAggregateDevice(_ deviceID: AudioObjectID) {
        _ = lock.withLock {
            deviceFormats.removeValue(forKey: deviceID)
        }
        logCleanupFailure(
            AudioHardwareDestroyAggregateDevice(deviceID),
            operation: .destroyAggregateDevice
        )
    }

    func destroyProcessTap(_ tapID: AudioObjectID) {
        lock.withLock {
            tapUIDs.removeValue(forKey: tapID)
            tapFormats.removeValue(forKey: tapID)
        }
        logCleanupFailure(
            AudioHardwareDestroyProcessTap(tapID),
            operation: .destroyProcessTap
        )
    }

    private func registration(
        for token: CoreAudioIOProcToken,
        deviceID: AudioObjectID
    ) -> IOProcRegistration? {
        lock.withLock {
            guard let registration = ioProcs[token.rawValue], registration.deviceID == deviceID else {
                return nil
            }
            return registration
        }
    }

    private func currentProcessObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID = getpid()
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var outputSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &processID) { processIDPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                processIDPointer,
                &outputSize,
                &processObjectID
            )
        }
        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            MLingoLogger.audio.debug("Could not exclude the MLingo process from the Core Audio mix")
            return nil
        }
        return processObjectID
    }

    private func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(
            tapID,
            &address,
            0,
            nil,
            &size,
            &format
        )
        try check(status, operation: .createProcessTap)
        return format
    }

    private func readTapUID(_ tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.stride)
        var uid: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &uid) { uidPointer in
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &size,
                uidPointer
            )
        }
        try check(status, operation: .createProcessTap)
        return uid as String
    }

    private func check(
        _ status: OSStatus,
        operation: CoreAudioHALOperation,
        permissionSensitive: Bool = false
    ) throws {
        guard status != noErr else { return }
        if permissionSensitive,
           status == kAudioDevicePermissionsError || status == OSStatus(0x7065_726D) {
            throw MLingoError.systemAudioPermissionDenied
        }
        throw MLingoError.coreAudioHALFailure(
            operation: operation.rawValue,
            status: status
        )
    }

    private func logCleanupFailure(_ status: OSStatus, operation: CoreAudioHALOperation) {
        guard status != noErr else { return }
        MLingoLogger.audio.error(
            "Core Audio cleanup failed during \(operation.rawValue, privacy: .public): OSStatus \(status, privacy: .public)"
        )
    }

    private static func timestamp(
        from inputTime: UnsafePointer<AudioTimeStamp>?,
        sampleRate: Double
    ) -> TimeInterval {
        guard let inputTime else { return ProcessInfo.processInfo.systemUptime }
        let time = inputTime.pointee
        if (time.mFlags.rawValue & 1) != 0, sampleRate > 0 {
            return time.mSampleTime / sampleRate
        }
        if (time.mFlags.rawValue & 2) != 0 {
            return TimeInterval(AudioConvertHostTimeToNanos(time.mHostTime)) / 1_000_000_000
        }
        return ProcessInfo.processInfo.systemUptime
    }
}
