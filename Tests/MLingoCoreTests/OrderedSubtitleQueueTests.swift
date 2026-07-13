import Foundation
import Testing
@testable import MLingoCore

@Test
func queueEmitsSubtitlesInTimelineOrder() {
    var queue = OrderedSubtitleQueue()
    let later = SubtitleItem(original: "later", translated: "sau", start: 2, end: 4)
    let earlier = SubtitleItem(original: "earlier", translated: "truoc", start: 0, end: 1)

    #expect(queue.insert(later).map(\.translated) == ["sau"])
    #expect(queue.insert(earlier).isEmpty)
}

@Test
func queueSuppressesDuplicateOriginalText() {
    var queue = OrderedSubtitleQueue()
    let first = SubtitleItem(original: "Hello", translated: "Xin chao", start: 0, end: 2)
    let duplicate = SubtitleItem(original: " hello ", translated: "Xin chao lai", start: 2, end: 4)

    #expect(queue.insert(first).count == 1)
    #expect(queue.insert(duplicate).isEmpty)
}
