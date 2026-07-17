import Foundation
import Testing
@testable import MLingoCore

/// Opt-in local MLX suite. Requires:
/// - `MLINGO_RUN_LOCAL_MLX_TESTS=1`
/// - `MLINGO_LOCAL_LLM_DIR`
/// - `MLINGO_LOCAL_EMBEDDING_DIR`
@Test
func builtInMLXLocalLLMRespondsAndTranslatesWhenEnabled() async throws {
    guard shouldRunLocalMLXTests else {
        return
    }
    let configuredDirectory = try localMLXModelDirectory(envName: "MLINGO_LOCAL_LLM_DIR")
    let modelDirectory = try #require(configuredDirectory)
    let provider = BuiltInMLXProvider()

    let chat = try await provider.respond(
        to: ChatRequest(
            messages: [ChatMessage(role: .user, content: "Reply with one short greeting.")],
            model: modelDirectory.path
        )
    )
    #expect(!chat.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

    let subtitle = try await provider.translate(
        TranslationProviderRequest(
            translation: TranslationRequest(current: Transcript(text: "Hello", timestamp: 12)),
            model: modelDirectory.path,
            sourceLanguage: "English",
            targetLanguage: "Vietnamese"
        )
    )
    #expect(subtitle.original == "Hello")
    #expect(!subtitle.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(subtitle.start == 12)
    #expect(subtitle.end == 15)
}

@Test
func builtInMLXLocalEmbeddingModelEmbedsWhenEnabled() async throws {
    guard shouldRunLocalMLXTests else {
        return
    }
    let configuredDirectory = try localMLXModelDirectory(envName: "MLINGO_LOCAL_EMBEDDING_DIR")
    let modelDirectory = try #require(configuredDirectory)
    let provider = BuiltInMLXProvider()

    let first = try await provider.embed(
        EmbeddingRequest(inputs: ["hello", "xin chao"], model: modelDirectory.path)
    )
    let second = try await provider.embed(
        EmbeddingRequest(inputs: ["hello", "xin chao"], model: modelDirectory.path)
    )

    #expect(first.vectors.count == 2)
    #expect(first.vectors.allSatisfy { !$0.isEmpty })
    #expect(first.vectors.map(\.count) == second.vectors.map(\.count))
    for vector in first.vectors {
        let norm = sqrt(vector.reduce(Double(0)) { $0 + Double($1 * $1) })
        #expect(abs(norm - 1) < 0.001)
    }
}

private var shouldRunLocalMLXTests: Bool {
    ProcessInfo.processInfo.environment["MLINGO_RUN_LOCAL_MLX_TESTS"] == "1"
}

private func localMLXModelDirectory(envName: String) throws -> URL? {
    guard shouldRunLocalMLXTests else { return nil }
    guard
        let rawValue = ProcessInfo.processInfo.environment[envName]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !rawValue.isEmpty
    else {
        throw MLingoError.localModelUnavailable("Set \(envName) to a local MLX model directory.")
    }

    let directory: URL
    if let url = URL(string: rawValue), url.isFileURL {
        directory = url
    } else {
        directory = URL(fileURLWithPath: rawValue, isDirectory: true)
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else {
        throw MLingoError.localModelUnavailable("\(envName) does not point to a directory.")
    }
    return directory.standardizedFileURL
}
