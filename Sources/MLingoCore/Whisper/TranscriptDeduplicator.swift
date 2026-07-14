import Foundation

struct TranscriptDeduplicator: Sendable {
    private let similarityThreshold: Double
    private let fuzzyOverlapThreshold: Double
    private var previousNormalizedText: String?
    private var previousTokens: [String] = []
    private(set) var suppressedCount = 0

    init(
        similarityThreshold: Double = 0.9,
        fuzzyOverlapThreshold: Double = 0.75
    ) {
        self.similarityThreshold = similarityThreshold
        self.fuzzyOverlapThreshold = fuzzyOverlapThreshold
    }

    mutating func process(
        _ transcript: Transcript,
        audioOverlapDuration: TimeInterval = 0
    ) -> Transcript? {
        let trimmedText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = Self.normalize(trimmedText)
        guard !normalizedText.isEmpty else {
            suppressedCount += 1
            return nil
        }

        let rawTokens = trimmedText.split(whereSeparator: \ .isWhitespace).map(String.init)
        let indexedNormalizedTokens = rawTokens.enumerated().flatMap { index, token in
            Self.normalizedTokens(token).map { normalizedToken in
                (rawIndex: index, token: normalizedToken)
            }
        }
        let normalizedTokens = indexedNormalizedTokens.map(\.token)

        if audioOverlapDuration > 0,
           let previousNormalizedText,
           Self.similarity(previousNormalizedText, normalizedText) >= similarityThreshold {
            suppressedCount += 1
            return nil
        }

        let overlapCount: Int
        if audioOverlapDuration > 0 {
            let maximumOverlapTokenCount = max(
                1,
                Int((audioOverlapDuration * 12).rounded(.up)) + 2
            )
            overlapCount = Self.longestSuffixPrefixOverlap(
                previous: previousTokens,
                current: normalizedTokens,
                maximumTokenCount: maximumOverlapTokenCount,
                fuzzyThreshold: fuzzyOverlapThreshold
            )
        } else {
            overlapCount = 0
        }

        previousNormalizedText = normalizedText
        previousTokens = normalizedTokens

        let rawOverlapCount = overlapCount > 0
            ? indexedNormalizedTokens[overlapCount - 1].rawIndex + 1
            : 0
        if rawOverlapCount > 0 {
            suppressedCount += 1
        }
        guard rawOverlapCount < rawTokens.count else {
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

    private static func normalizedTokens(_ text: String) -> [String] {
        normalize(text).split(whereSeparator: \ .isWhitespace).map(String.init)
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
        current: [String],
        maximumTokenCount: Int,
        fuzzyThreshold: Double
    ) -> Int {
        let maximumOverlap = min(previous.count, current.count, maximumTokenCount)
        guard maximumOverlap > 0 else { return 0 }

        for count in stride(from: maximumOverlap, through: 1, by: -1) {
            if previous.suffix(count).elementsEqual(current.prefix(count)) {
                return count
            }
        }

        guard maximumOverlap >= 4 else { return 0 }
        var bestCurrentCount = 0
        var bestSimilarity = 0.0

        for currentCount in 4...maximumOverlap {
            let minimumPreviousCount = max(4, currentCount - 2)
            let maximumPreviousCount = min(maximumOverlap, currentCount + 2)
            guard minimumPreviousCount <= maximumPreviousCount else { continue }

            for previousCount in minimumPreviousCount...maximumPreviousCount {
                let previousSuffix = Array(previous.suffix(previousCount))
                let currentPrefix = Array(current.prefix(currentCount))
                let sharesBoundaryAnchor = previousSuffix.first == currentPrefix.first
                    || previousSuffix.last == currentPrefix.last
                guard sharesBoundaryAnchor else {
                    continue
                }

                let maximumLength = max(previousCount, currentCount)
                let similarity = 1 - (
                    Double(tokenEditDistance(previousSuffix, currentPrefix))
                        / Double(maximumLength)
                )
                guard similarity >= fuzzyThreshold else { continue }

                if currentCount > bestCurrentCount
                    || (currentCount == bestCurrentCount && similarity > bestSimilarity)
                {
                    bestCurrentCount = currentCount
                    bestSimilarity = similarity
                }
            }
        }

        return bestCurrentCount
    }

    private static func tokenEditDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        var previous = Array(0...rhs.count)

        for (leftIndex, leftToken) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = leftIndex + 1

            for (rightIndex, rightToken) in rhs.enumerated() {
                let substitutionCost = leftToken == rightToken ? 0 : 1
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + substitutionCost
                )
            }

            previous = current
        }

        return previous[rhs.count]
    }
}
