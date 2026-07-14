import Foundation

public struct TranscriptLogEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let receivedAt: Date

    public init(
        transcript: Transcript,
        receivedAt: Date = Date()
    ) {
        id = transcript.id
        text = transcript.text
        self.receivedAt = receivedAt
    }

    public func timestampPrefix(in timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents(
            [.hour, .minute, .second, .nanosecond],
            from: receivedAt
        )
        let milliseconds = (components.nanosecond ?? 0) / 1_000_000
        return String(
            format: "%02d:%02d:%02d.%03d",
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            milliseconds
        )
    }
}
