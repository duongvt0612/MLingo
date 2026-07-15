import Foundation

public enum ProviderDiagnosticRedactor {
    public static func redactSecrets(in text: String, secrets: [String]) -> String {
        redact(in: text, secrets: secrets, userTexts: [])
    }

    public static func redactUserText(in text: String, userTexts: [String]) -> String {
        redact(in: text, secrets: [], userTexts: userTexts)
    }

    public static func safeDescription(
        _ text: String,
        secrets: [String] = [],
        userTexts: [String] = []
    ) -> String {
        redact(in: text, secrets: secrets, userTexts: userTexts)
    }

    public static func redactAuthorizationHeader(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "[absent]" }
        if value.lowercased().hasPrefix("bearer ") {
            return "Bearer [redacted]"
        }
        return "[redacted]"
    }

    /// Server-controlled headers (e.g. `x-request-id`) must not be logged raw.
    /// A full ASCII whitelist match (`[A-Za-z0-9_-]{1,64}`) is acknowledged only as
    /// `[redacted]`; malformed values return `unavailable`.
    public static func sanitizeServerControlledHeader(_ value: String?) -> String {
        guard let value else { return "unavailable" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return "unavailable" }
        let isAllowedASCII = trimmed.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
                || value == 45
                || value == 95
        }
        guard isAllowedASCII else {
            return "unavailable"
        }
        return "[redacted]"
    }

    private static func redact(
        in text: String,
        secrets: [String],
        userTexts: [String]
    ) -> String {
        var replacements: [Replacement] = []
        appendReplacements(secrets, marker: "[redacted]", to: &replacements)
        appendReplacements(userTexts, marker: "[user-text]", to: &replacements)
        replacements.sort { lhs, rhs in
            lhs.value.count == rhs.value.count
                ? lhs.marker < rhs.marker
                : lhs.value.count > rhs.value.count
        }
        guard !replacements.isEmpty else { return text }

        var matches: [Match] = []
        for replacement in replacements {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(
                      of: replacement.value,
                      range: searchStart..<text.endIndex
                  )
            {
                matches.append(Match(range: range, marker: replacement.marker))
                searchStart = text.index(after: range.lowerBound)
            }
        }
        guard !matches.isEmpty else { return text }
        matches.sort { lhs, rhs in
            if lhs.range.lowerBound == rhs.range.lowerBound {
                return lhs.range.upperBound > rhs.range.upperBound
            }
            return lhs.range.lowerBound < rhs.range.lowerBound
        }

        var merged: [Match] = []
        for match in matches {
            guard let last = merged.last,
                  match.range.lowerBound < last.range.upperBound
            else {
                merged.append(match)
                continue
            }
            let upperBound = max(last.range.upperBound, match.range.upperBound)
            let marker = last.marker == "[redacted]" || match.marker == "[redacted]"
                ? "[redacted]"
                : "[user-text]"
            merged[merged.count - 1] = Match(
                range: last.range.lowerBound..<upperBound,
                marker: marker
            )
        }

        var result = ""
        var cursor = text.startIndex
        for match in merged {
            result.append(contentsOf: text[cursor..<match.range.lowerBound])
            result.append(match.marker)
            cursor = match.range.upperBound
        }
        result.append(contentsOf: text[cursor...])
        return result
    }

    private static func appendReplacements(
        _ values: [String],
        marker: String,
        to replacements: inout [Replacement]
    ) {
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !replacements.contains(where: { $0.value == trimmed })
            else { continue }
            replacements.append(Replacement(value: trimmed, marker: marker))
        }
    }

    private struct Replacement {
        let value: String
        let marker: String
    }

    private struct Match {
        let range: Range<String.Index>
        let marker: String
    }
}
