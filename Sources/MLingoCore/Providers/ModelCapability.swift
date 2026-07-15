import Foundation

public enum ModelCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case speechRecognition
    case translation
    case chat
    case embedding
    case textToSpeech
}
