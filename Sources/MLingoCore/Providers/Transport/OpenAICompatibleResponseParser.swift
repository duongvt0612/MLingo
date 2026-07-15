import Foundation

public struct TokenUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

public struct OpenAICompatibleCompletionResult: Sendable, Equatable {
    public var text: String
    public var usage: TokenUsage?

    public init(text: String, usage: TokenUsage? = nil) {
        self.text = text
        self.usage = usage
    }
}

public enum OpenAICompatibleResponseParser {
    public static func parse(
        data: Data,
        style: ProviderAPIStyle
    ) throws -> OpenAICompatibleCompletionResult {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MLingoError.invalidResponse
        }
        guard let dictionary = object as? [String: Any] else {
            throw MLingoError.invalidResponse
        }

        if dictionary["object"] as? String == "error"
            || dictionary["error"] != nil && dictionary["choices"] == nil
                && dictionary["output"] == nil && dictionary["output_text"] == nil
        {
            let statusCode = dictionary["status"] as? String == "failed" ? 500 : 400
            throw OpenAICompatibleErrorMapper.mapAPIError(
                from: dictionary,
                statusCode: statusCode
            )
        }

        switch style {
        case .responses:
            return try parseResponses(dictionary)
        case .chatCompletions:
            return try parseChatCompletions(dictionary)
        case .native:
            throw MLingoError.invalidResponse
        }
    }

    private static func parseResponses(
        _ dictionary: [String: Any]
    ) throws -> OpenAICompatibleCompletionResult {
        if let status = dictionary["status"] as? String {
            switch status {
            case "failed":
                throw OpenAICompatibleErrorMapper.mapAPIError(
                    from: dictionary,
                    statusCode: 500
                )
            case "incomplete", "cancelled":
                throw MLingoError.invalidResponse
            case "completed":
                break
            default:
                throw MLingoError.invalidResponse
            }
        }

        if let outputText = dictionary["output_text"] as? String {
            let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return OpenAICompatibleCompletionResult(
                    text: trimmed,
                    usage: parseUsage(dictionary["usage"])
                )
            }
        }

        if let output = dictionary["output"] as? [[String: Any]] {
            let text = output
                .flatMap { item -> [[String: Any]] in
                    item["content"] as? [[String: Any]] ?? []
                }
                .compactMap { content -> String? in
                    if let type = content["type"] as? String, type != "output_text" {
                        return nil
                    }
                    if let text = content["text"] as? String {
                        return text
                    }
                    if let text = content["output_text"] as? String {
                        return text
                    }
                    return nil
                }
                .joined(separator: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                return OpenAICompatibleCompletionResult(
                    text: text,
                    usage: parseUsage(dictionary["usage"])
                )
            }
        }

        throw MLingoError.invalidResponse
    }

    private static func parseChatCompletions(
        _ dictionary: [String: Any]
    ) throws -> OpenAICompatibleCompletionResult {
        // Streaming payloads are not accepted for complete translation.
        if dictionary["object"] as? String == "chat.completion.chunk" {
            throw MLingoError.invalidResponse
        }
        if let choices = dictionary["choices"] as? [[String: Any]],
           let first = choices.first,
           first["delta"] != nil
        {
            throw MLingoError.invalidResponse
        }

        guard
            let choices = dictionary["choices"] as? [[String: Any]],
            let first = choices.first
        else {
            throw MLingoError.invalidResponse
        }

        if let message = first["message"] as? [String: Any] {
            if let content = message["content"] as? String {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return OpenAICompatibleCompletionResult(
                        text: trimmed,
                        usage: parseUsage(dictionary["usage"])
                    )
                }
            }
            // Multimodal content array form
            if let parts = message["content"] as? [[String: Any]] {
                let text = parts
                    .compactMap { part -> String? in
                        if let type = part["type"] as? String, type != "text" {
                            return nil
                        }
                        return part["text"] as? String
                    }
                    .joined(separator: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return OpenAICompatibleCompletionResult(
                        text: text,
                        usage: parseUsage(dictionary["usage"])
                    )
                }
            }
        }

        throw MLingoError.invalidResponse
    }

    private static func parseUsage(_ value: Any?) -> TokenUsage? {
        guard let usage = value as? [String: Any] else { return nil }
        let input = intValue(usage["input_tokens"] ?? usage["prompt_tokens"])
        let output = intValue(usage["output_tokens"] ?? usage["completion_tokens"])
        let total = intValue(usage["total_tokens"])
        if input == nil, output == nil, total == nil {
            return nil
        }
        return TokenUsage(inputTokens: input, outputTokens: output, totalTokens: total)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
