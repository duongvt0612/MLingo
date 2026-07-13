import Foundation

public enum TranslationResponseParser {
    public static func parse(data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw MLingoError.invalidResponse
        }

        if let outputText = dictionary["output_text"] as? String, !outputText.isEmpty {
            return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let output = dictionary["output"] as? [[String: Any]] {
            let text = output
                .flatMap { item -> [[String: Any]] in
                    item["content"] as? [[String: Any]] ?? []
                }
                .compactMap { content -> String? in
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
}
