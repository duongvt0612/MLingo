import Foundation

struct TranscriptDeduplicator: Sendable {
    private let similarityThreshold: Double
    private var previousNormalizedText: String?
    private var previousTokens: [String] = []
    private(set) var suppressedCount = 0

    init(similarityThreshold: Double = 0.9) {
        self.similarityThreshold = similarityThreshold
    }

    mutating func process(_ transcript: Transcript) -> Transcript? {
        let trimmedText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = Self.normalize(trimmedText)
        guard !normalizedText.isEmpty else {
            suppressedCount += 1
            return nil
        }

        let rawTokens = trimmedText.split(whereSeparator: \ .isWhitespace).map(String.init)
        let indexedNormalizedTokens = rawTokens.enumerated().compactMap { index, token in
            let normalizedToken = Self.normalize(token)
            return normalizedToken.isEmpty ? nil : (rawIndex: index, token: normalizedToken)
        }
        let normalizedTokens = indexedNormalizedTokens.map(\.token)

        if let previousNormalizedText,
           Self.similarity(previousNormalizedText, normalizedText) >= similarityThreshold {
            suppressedCount += 1
            return nil
        }

        let overlapCount = Self.longestSuffixPrefixOverlap(
            previous: previousTokens,
            current: normalizedTokens
        )

        previousNormalizedText = normalizedText
        previousTokens = normalizedTokens

        let rawOverlapCount = overlapCount > 0
            ? indexedNormalizedTokens[overlapCount - 1].rawIndex + 1
            : 0
        guard rawOverlapCount < rawTokens.count else {
            suppressedCount += 1
            return nil
        }

        let newText = rawTokens.dropFirst(rawOverlapCount).joined(separator: " ")
        guard !newText.isEmpty else {
            suppressedCount += 1
            return nil
        }

        return Transcript(id: transcript.id, text: newText, timestamp: transcript.timestamp)
    }

    mutating func reset() {
        previousNormalizedText = nil
        previousTokens = []
        suppressedCount = 0
    }

    private static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let normalizedCharacters = folded.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(normalizedCharacters)
            .split(whereSeparator: \ .isWhitespace)
            .joined(separator: " ")
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let maximumLength = max(lhs.count, rhs.count)
        guard maximumLength > 0 else { return 1 }
        return 1 - (Double(editDistance(lhs, rhs)) / Double(maximumLength))
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)

        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1

            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitutionCost = leftCharacter == rightCharacter ? 0 : 1
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + substitutionCost
                )
            }

            previous = current
        }

        return previous[right.count]
    }

    private static func longestSuffixPrefixOverlap(
        previous: [String],
        current: [String]
    ) -> Int {
        let maximumOverlap = min(previous.count, current.count)
        guard maximumOverlap >= 2 else { return 0 }

        for count in stride(from: maximumOverlap, through: 2, by: -1) {
            if previous.suffix(count).elementsEqual(current.prefix(count)) {
                return count
            }
        }

        return 0
    }
}
