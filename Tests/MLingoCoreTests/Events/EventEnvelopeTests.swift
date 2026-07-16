import Foundation
import Testing
@testable import MLingoCore

@Test
func eventEnvelopePreservesInjectedMetadataAndRoundTripsCodablePayload() throws {
    let eventID = EventID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let sessionID = SessionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let traceID = TraceID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    let timestamp = Date(timeIntervalSince1970: 1_721_111_111)
    let payload = SessionStarted(kind: .translation)

    let envelope = EventEnvelope(
        id: eventID,
        sessionID: sessionID,
        sequence: 42,
        timestamp: timestamp,
        traceID: traceID,
        payload: payload
    )

    #expect(envelope.id == eventID)
    #expect(envelope.sessionID == sessionID)
    #expect(envelope.sequence == 42)
    #expect(envelope.timestamp == timestamp)
    #expect(envelope.traceID == traceID)
    #expect(envelope.payload == payload)

    let encoded = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(EventEnvelope<SessionStarted>.self, from: encoded)
    #expect(decoded == envelope)
}

@Test
func eventIdentifierWrappersRoundTripWithoutLosingTypeIdentity() throws {
    let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    let eventID = EventID(rawValue: uuid)
    let sessionID = SessionID(rawValue: uuid)
    let traceID = TraceID(rawValue: uuid)

    #expect(try JSONDecoder().decode(EventID.self, from: JSONEncoder().encode(eventID)) == eventID)
    #expect(try JSONDecoder().decode(SessionID.self, from: JSONEncoder().encode(sessionID)) == sessionID)
    #expect(try JSONDecoder().decode(TraceID.self, from: JSONEncoder().encode(traceID)) == traceID)
    #expect(eventID.rawValue == sessionID.rawValue)
    #expect(traceID.rawValue == eventID.rawValue)
}

