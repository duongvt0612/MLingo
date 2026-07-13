import Foundation

public enum AudioCaptureState: Equatable, Sendable {
    case idle
    case requestingPermission
    case running
    case stopped
    case failed(String)
}

public protocol AudioEngineProtocol: AnyObject, Sendable {
    var chunks: AsyncStream<AudioChunk> { get }
    var state: AudioCaptureState { get async }

    func start() async throws
    func stop() async
}
