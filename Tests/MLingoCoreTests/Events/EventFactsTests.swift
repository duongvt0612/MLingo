import Foundation
import Testing
@testable import MLingoCore

@Test
func eventFactsAreImmutableCodableEquatableSendableContracts() throws {
    let transcript = Transcript(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        text: "Ship the event hub.",
        timestamp: 12.5
    )
    let subtitle = SubtitleItem(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        original: transcript.text,
        translated: "Phat hanh event hub.",
        start: 12.5,
        end: 14
    )

    try assertEventFactRoundTrip(SessionStarted(kind: .transcription))
    try assertEventFactRoundTrip(SessionStarted(kind: .translation))
    try assertEventFactRoundTrip(SessionEnded(reason: .completed))
    try assertEventFactRoundTrip(SessionEnded(reason: .cancelled))
    try assertEventFactRoundTrip(SessionEnded(reason: .failed))
    try assertEventFactRoundTrip(TranscriptCompleted(transcript: transcript))
    try assertEventFactRoundTrip(
        TranslationCompleted(sourceTranscriptID: transcript.id, subtitle: subtitle)
    )
}

private func assertEventFactRoundTrip<Event>(
    _ event: Event
) throws where Event: EventFact & Codable & Equatable {
    let sendableEvent: any Sendable = event
    _ = sendableEvent

    let data = try JSONEncoder().encode(event)
    let decoded = try JSONDecoder().decode(Event.self, from: data)
    #expect(decoded == event)
}
