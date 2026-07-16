import Foundation

public enum SessionKind: String, Codable, Equatable, Sendable {
    case transcription
    case translation
}

public struct SessionStarted: EventFact, Codable, Equatable {
    public let kind: SessionKind

    public init(kind: SessionKind) {
        self.kind = kind
    }
}

public enum SessionEndReason: String, Codable, Equatable, Sendable {
    case completed
    case cancelled
    case failed
}

public struct SessionEnded: EventFact, Codable, Equatable {
    public let reason: SessionEndReason

    public init(reason: SessionEndReason) {
        self.reason = reason
    }
}

public struct TranscriptCompleted: EventFact, Codable, Equatable {
    public let transcript: Transcript

    public init(transcript: Transcript) {
        self.transcript = transcript
    }
}

public struct TranslationCompleted: EventFact, Codable, Equatable {
    public let sourceTranscriptID: UUID
    public let subtitle: SubtitleItem

    public init(sourceTranscriptID: UUID, subtitle: SubtitleItem) {
        self.sourceTranscriptID = sourceTranscriptID
        self.subtitle = subtitle
    }
}
