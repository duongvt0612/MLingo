import Foundation
import Testing
@testable import MLingoCore

@Test
func modelCapabilitiesAreStableAndIndependentlySelectable() {
    #expect(ModelCapability.allCases == [
        .speechRecognition,
        .translation,
        .chat,
        .embedding,
        .textToSpeech,
    ])
    #expect(ModelCapability.textToSpeech.rawValue == "textToSpeech")
}

@Test
func capabilityProviderContractsAcceptTypedRequests() async throws {
    let transcript = try await CapabilitySpeechProvider().transcribe(
        SpeechRecognitionRequest(
            audio: AudioChunk(
                samples: [0.25],
                sampleRate: 16_000,
                channelCount: 1,
                timestamp: 2,
                duration: 1.0 / 16_000
            ),
            language: "en",
            model: "whisper-test"
        )
    )
    #expect(transcript?.text == "hello")

    let subtitle = try await CapabilityTranslationProvider().translate(
        TranslationProviderRequest(
            translation: TranslationRequest(
                current: Transcript(text: "hello", timestamp: 2)
            ),
            model: "translation-test",
            sourceLanguage: "English",
            targetLanguage: "Vietnamese"
        )
    )
    #expect(subtitle.translated == "xin chao")

    let chat = try await CapabilityChatProvider().respond(
        to: ChatRequest(
            messages: [ChatMessage(role: .user, content: "Explain")],
            model: "chat-test"
        )
    )
    #expect(chat.text == "Explanation")

    let embedding = try await CapabilityEmbeddingProvider().embed(
        EmbeddingRequest(inputs: ["hello"], model: "embedding-test")
    )
    #expect(embedding.vectors == [[0.1, 0.2]])

    let speech = try await CapabilityTTSProvider().speak(
        TTSRequest(text: "xin chao", model: "system", voice: "default")
    )
    #expect(speech.spokenCharacterCount == 8)
}

private actor CapabilitySpeechProvider: SpeechRecognitionProvider {
    func transcribe(_ request: SpeechRecognitionRequest) async throws -> Transcript? {
        Transcript(text: "hello", timestamp: request.audio.timestamp)
    }
}

private actor CapabilityTranslationProvider: TranslationProvider {
    func translate(_ request: TranslationProviderRequest) async throws -> SubtitleItem {
        SubtitleItem(
            original: request.translation.current.text,
            translated: "xin chao",
            start: request.translation.current.timestamp,
            end: request.translation.current.timestamp + 3
        )
    }
}

private actor CapabilityChatProvider: ChatProvider {
    func respond(to request: ChatRequest) async throws -> ChatResponse {
        ChatResponse(text: "Explanation")
    }
}

private actor CapabilityEmbeddingProvider: EmbeddingProvider {
    func embed(_ request: EmbeddingRequest) async throws -> EmbeddingResponse {
        EmbeddingResponse(vectors: [[0.1, 0.2]])
    }
}

private actor CapabilityTTSProvider: TTSProvider {
    func speak(_ request: TTSRequest) async throws -> TTSResult {
        TTSResult(spokenCharacterCount: request.text.count)
    }
}
