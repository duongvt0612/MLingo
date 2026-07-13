import Foundation

public struct Transcript: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let timestamp: TimeInterval

    public init(id: UUID = UUID(), text: String, timestamp: TimeInterval) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
    }
}
