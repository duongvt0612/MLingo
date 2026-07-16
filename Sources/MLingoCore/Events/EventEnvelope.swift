import Foundation

public protocol EventFact: Sendable {}

public struct EventID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct SessionID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct TraceID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct SubscriptionToken: RawRepresentable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct EventEnvelope<Event: EventFact>: Sendable {
    public let id: EventID
    public let sessionID: SessionID
    public let sequence: UInt64
    public let timestamp: Date
    public let traceID: TraceID
    public let payload: Event

    public init(
        id: EventID,
        sessionID: SessionID,
        sequence: UInt64,
        timestamp: Date,
        traceID: TraceID,
        payload: Event
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.timestamp = timestamp
        self.traceID = traceID
        self.payload = payload
    }
}

extension EventEnvelope: Equatable where Event: Equatable {}
extension EventEnvelope: Codable where Event: Codable {}

