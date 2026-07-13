import Foundation

public struct SubtitleItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let original: String
    public let translated: String
    public let start: Double
    public let end: Double

    public init(
        id: UUID = UUID(),
        original: String,
        translated: String,
        start: Double,
        end: Double
    ) {
        self.id = id
        self.original = original
        self.translated = translated
        self.start = start
        self.end = end
    }
}
