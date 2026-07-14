import Foundation

public enum WhisperModelState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)
}

public struct WhisperDiagnostics: Equatable, Sendable {
    public var modelState: WhisperModelState
    public var modelID: String
    public var lastTranscript: String
    public var inferenceLatency: TimeInterval
    public var windowDuration: TimeInterval
    public var processedWindowCount: Int
    public var suppressedDuplicateCount: Int
    public var droppedBacklogWindowCount: Int

    public init(
        modelState: WhisperModelState = .idle,
        modelID: String = "",
        lastTranscript: String = "",
        inferenceLatency: TimeInterval = 0,
        windowDuration: TimeInterval = 0,
        processedWindowCount: Int = 0,
        suppressedDuplicateCount: Int = 0,
        droppedBacklogWindowCount: Int = 0
    ) {
        self.modelState = modelState
        self.modelID = modelID
        self.lastTranscript = lastTranscript
        self.inferenceLatency = inferenceLatency
        self.windowDuration = windowDuration
        self.processedWindowCount = processedWindowCount
        self.suppressedDuplicateCount = suppressedDuplicateCount
        self.droppedBacklogWindowCount = droppedBacklogWindowCount
    }
}
