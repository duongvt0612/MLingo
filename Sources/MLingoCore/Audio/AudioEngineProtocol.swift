import Foundation

public enum AudioCaptureState: Equatable, Sendable {
    case idle
    case requestingPermission
    case running
    case stopped
    case failed(String)
}

public struct AudioCaptureDiagnostics: Equatable, Sendable {
    public var rms: Float
    public var peak: Float
    public var sampleRate: Double
    public var channelCount: Int
    public var lastChunkDuration: TimeInterval
    public var capturedChunkCount: Int
    public var droppedChunkCount: Int
    public var emptyChunkCount: Int
    public var speechLikeChunkCount: Int
    public var vadThreshold: Float
    public var lastUpdated: Date?
    public var state: AudioCaptureState

    public init(
        rms: Float = 0,
        peak: Float = 0,
        sampleRate: Double = 0,
        channelCount: Int = 0,
        lastChunkDuration: TimeInterval = 0,
        capturedChunkCount: Int = 0,
        droppedChunkCount: Int = 0,
        emptyChunkCount: Int = 0,
        speechLikeChunkCount: Int = 0,
        vadThreshold: Float = AudioLevelAnalyzer.defaultVADThreshold,
        lastUpdated: Date? = nil,
        state: AudioCaptureState = .idle
    ) {
        self.rms = rms
        self.peak = peak
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.lastChunkDuration = lastChunkDuration
        self.capturedChunkCount = capturedChunkCount
        self.droppedChunkCount = droppedChunkCount
        self.emptyChunkCount = emptyChunkCount
        self.speechLikeChunkCount = speechLikeChunkCount
        self.vadThreshold = vadThreshold
        self.lastUpdated = lastUpdated
        self.state = state
    }
}

public protocol AudioEngineProtocol: AnyObject, Sendable {
    var chunks: AsyncStream<AudioChunk> { get }
    var diagnostics: AsyncStream<AudioCaptureDiagnostics> { get }
    var state: AudioCaptureState { get async }

    func start() async throws
    func stop() async
}

public protocol AudioEngineFactoryProtocol: Sendable {
    func makeAudioEngine() -> any AudioEngineProtocol
}

public struct SystemAudioEngineFactory: AudioEngineFactoryProtocol {
    private let isCoreAudioTapAvailable: Bool
    private let makeCoreAudioTapEngine: @Sendable () -> any AudioEngineProtocol
    private let makeScreenCaptureKitEngine: @Sendable () -> any AudioEngineProtocol

    public init() {
        if #available(macOS 14.2, *) {
            isCoreAudioTapAvailable = true
            makeCoreAudioTapEngine = { CoreAudioTapEngine() }
        } else {
            isCoreAudioTapAvailable = false
            makeCoreAudioTapEngine = { ScreenCaptureAudioEngine() }
        }
        makeScreenCaptureKitEngine = { ScreenCaptureAudioEngine() }
    }

    init(
        isCoreAudioTapAvailable: Bool,
        makeCoreAudioTapEngine: @escaping @Sendable () -> any AudioEngineProtocol,
        makeScreenCaptureKitEngine: @escaping @Sendable () -> any AudioEngineProtocol
    ) {
        self.isCoreAudioTapAvailable = isCoreAudioTapAvailable
        self.makeCoreAudioTapEngine = makeCoreAudioTapEngine
        self.makeScreenCaptureKitEngine = makeScreenCaptureKitEngine
    }

    public func makeAudioEngine() -> any AudioEngineProtocol {
        if isCoreAudioTapAvailable {
            makeCoreAudioTapEngine()
        } else {
            makeScreenCaptureKitEngine()
        }
    }
}
