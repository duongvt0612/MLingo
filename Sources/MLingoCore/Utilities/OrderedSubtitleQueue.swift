import Foundation

public struct OrderedSubtitleQueue: Sendable {
    private var seenOriginals = Set<String>()
    private var pending: [SubtitleItem] = []
    private var lastEmittedEnd: Double = 0

    public init() {}

    public mutating func insert(_ item: SubtitleItem) -> [SubtitleItem] {
        let dedupeKey = item.original
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !dedupeKey.isEmpty, !seenOriginals.contains(dedupeKey), item.end > lastEmittedEnd else {
            return []
        }

        seenOriginals.insert(dedupeKey)
        pending.append(item)
        pending.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.start < rhs.start
        }

        var ready: [SubtitleItem] = []
        while let first = pending.first {
            guard first.start >= lastEmittedEnd else {
                pending.removeFirst()
                continue
            }

            ready.append(first)
            lastEmittedEnd = max(lastEmittedEnd, first.end)
            pending.removeFirst()
        }

        return ready
    }
}
