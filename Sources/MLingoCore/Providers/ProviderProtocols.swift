import Foundation

public struct SpeechRecognitionRequest: Equatable, Sendable {
    public let audio: AudioChunk
    public let language: String
    public let model: String

    public init(audio: AudioChunk, language: String, model: String) {
        self.audio = audio
        self.language = language
        self.model = model
    }
}

public protocol SpeechRecognitionProvider: AnyObject, Sendable {
    func transcribe(_ request: SpeechRecognitionRequest) async throws -> Transcript?
}

public struct TranslationProviderRequest: Equatable, Sendable {
    public let translation: TranslationRequest
    public let model: String
    public let sourceLanguage: String
    public let targetLanguage: String

    public init(
        translation: TranslationRequest,
        model: String,
        sourceLanguage: String,
        targetLanguage: String
    ) {
        self.translation = translation
        self.model = model
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

public protocol TranslationProvider: AnyObject, Sendable {
    func translate(_ request: TranslationProviderRequest) async throws -> SubtitleItem
}

public enum ChatRole: String, Codable, Equatable, Sendable {
    case system
    case user
    case assistant
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public let role: ChatRole
    public let content: String

    public init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ChatRequest: Equatable, Sendable {
    public let messages: [ChatMessage]
    public let model: String

    public init(messages: [ChatMessage], model: String) {
        self.messages = messages
        self.model = model
    }
}

public struct ChatResponse: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public protocol ChatProvider: AnyObject, Sendable {
    func respond(to request: ChatRequest) async throws -> ChatResponse
}

public protocol ChatStreamingProvider: ChatProvider {
    func streamResponse(to request: ChatRequest) -> AsyncThrowingStream<String, Error>
}

public struct EmbeddingRequest: Equatable, Sendable {
    public let inputs: [String]
    public let model: String

    public init(inputs: [String], model: String) {
        self.inputs = inputs
        self.model = model
    }
}

public struct EmbeddingResponse: Equatable, Sendable {
    public let vectors: [[Float]]

    public init(vectors: [[Float]]) {
        self.vectors = vectors
    }
}

public protocol EmbeddingProvider: AnyObject, Sendable {
    func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResponse
}

public struct TTSRequest: Equatable, Sendable {
    public let text: String
    public let model: String
    public let voice: String?

    public init(text: String, model: String, voice: String? = nil) {
        self.text = text
        self.model = model
        self.voice = voice
    }
}

public struct TTSResult: Equatable, Sendable {
    public let spokenCharacterCount: Int

    public init(spokenCharacterCount: Int) {
        self.spokenCharacterCount = spokenCharacterCount
    }
}

public protocol TTSProvider: AnyObject, Sendable {
    func speak(_ request: TTSRequest) async throws -> TTSResult
}
