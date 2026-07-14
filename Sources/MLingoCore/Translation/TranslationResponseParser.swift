import Foundation

public enum TranslationResponseParser {
    public static func parse(data: Data) throws -> String {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MLingoError.invalidResponse
        }
        guard let dictionary = object as? [String: Any] else {
            throw MLingoError.invalidResponse
        }

        if let status = dictionary["status"] as? String {
            switch status {
            case "failed":
                throw apiError(from: dictionary, statusCode: 500)
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
            if !trimmed.isEmpty { return trimmed }
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
                return text
            }
        }

        throw MLingoError.invalidResponse
    }

    static func apiError(data: Data, statusCode: Int) -> MLingoError {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return fallbackError(statusCode: statusCode, message: nil)
        }
        return apiError(from: dictionary, statusCode: statusCode)
    }

    private static func apiError(
        from dictionary: [String: Any],
        statusCode: Int
    ) -> MLingoError {
        let payload = dictionary["error"] as? [String: Any]
        let code = (payload?["code"] as? String)?.lowercased()
        let type = (payload?["type"] as? String)?.lowercased()
        let message = payload?["message"] as? String
        let identifiers = [code, type].compactMap { $0 }

        if statusCode == 401 || identifiers.contains(where: { $0.contains("invalid_api_key") }) {
            return .invalidAPIKey
        }
        if identifiers.contains(where: { $0.contains("model_not_found") }) {
            return .invalidOpenAIModel
        }
        if identifiers.contains(where: { $0.contains("quota") || $0.contains("billing") }) {
            return .quotaExceeded
        }
        if statusCode == 429 {
            return .rateLimited
        }
        return fallbackError(statusCode: statusCode, message: message)
    }

    private static func fallbackError(statusCode: Int, message: String?) -> MLingoError {
        if (500..<600).contains(statusCode) {
            return .translationServiceUnavailable
        }
        if statusCode == 404 {
            return .invalidOpenAIModel
        }
        let fallback = "OpenAI rejected the translation request (HTTP \(statusCode))."
        let resolvedMessage = message?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? fallback
        if (400..<500).contains(statusCode) {
            return .translationRequestRejected(resolvedMessage)
        }
        return .translationFailed(resolvedMessage)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
