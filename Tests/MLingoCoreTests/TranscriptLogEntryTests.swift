import Foundation
import Testing
@testable import MLingoCore

@Test
func transcriptLogEntryFormatsWallClockToMilliseconds() throws {
    var calendar = Calendar(identifier: .gregorian)
    let timeZone = try #require(TimeZone(secondsFromGMT: 0))
    calendar.timeZone = timeZone
    let receivedAt = try #require(
        calendar.date(
            from: DateComponents(
                year: 2026,
                month: 7,
                day: 14,
                hour: 13,
                minute: 5,
                second: 9,
                nanosecond: 123_000_000
            )
        )
    )
    let transcript = Transcript(text: "Hello", timestamp: 42)
    let entry = TranscriptLogEntry(transcript: transcript, receivedAt: receivedAt)

    #expect(entry.id == transcript.id)
    #expect(entry.text == "Hello")
    #expect(entry.timestampPrefix(in: timeZone) == "13:05:09.123")
}
