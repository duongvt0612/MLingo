import Foundation
import Testing
@testable import MLingoCore

@Test
func adaptiveWindowFlushesShortSpeechAfterSilence() throws {
    var accumulator = AdaptiveAudioWindowAccumulator()

    #expect(accumulator.append(chunk(duration: 0.2, timestamp: 10)).isEmpty)
    #expect(accumulator.append(chunk(duration: 0.25, timestamp: 10.2)).isEmpty)

    let flushedWindow = accumulator.flushForSilence()
    let window = try #require(flushedWindow)
    #expect(abs(window.duration - 0.45) < 0.001)
    #expect(window.timestamp == 10)
    #expect(window.samples.count == 7_200)
    #expect(accumulator.bufferedDuration == 0)
}

@Test
func adaptiveWindowIgnoresSpeechBelowMinimumDuration() {
    var accumulator = AdaptiveAudioWindowAccumulator()

    _ = accumulator.append(chunk(duration: 0.2, timestamp: 5))

    #expect(accumulator.flushForSilence() == nil)
    #expect(accumulator.bufferedDuration == 0)
}

@Test
func adaptiveWindowEmitsAtPreferredTargetAndRetainsOverlap() throws {
    var accumulator = AdaptiveAudioWindowAccumulator()

    let emitted = accumulator.append(chunk(duration: 3.2, timestamp: 20))

    #expect(emitted.count == 2)
    #expect(abs(emitted[0].duration - 1.5) < 0.001)
    #expect(abs(emitted[1].duration - 1.5) < 0.001)
    #expect(emitted[0].timestamp == 20)
    #expect(abs(emitted[1].timestamp - 21.1) < 0.001)
    #expect(abs(accumulator.bufferedDuration - 1.0) < 0.001)
    #expect(abs(accumulator.bufferedTimestamp - 22.2) < 0.001)
}

@Test
func adaptiveWindowHonorsConfiguredHardLimit() throws {
    let configuration = AdaptiveAudioWindowConfiguration(
        preferredWindowDuration: 3,
        maximumWindowDuration: 3
    )
    var accumulator = AdaptiveAudioWindowAccumulator(configuration: configuration)

    let emitted = accumulator.append(chunk(duration: 3.2, timestamp: 20))
    let window = try #require(emitted.first)

    #expect(emitted.count == 1)
    #expect(abs(window.duration - 3.0) < 0.001)
    #expect(window.samples.count == 48_000)
}

@Test
func adaptiveWindowAlwaysAdvancesWhenRoundedOverlapFillsWindow() {
    #expect(
        AdaptiveAudioWindowAccumulator.retainedStartIndex(
            maximumSampleCount: 1,
            overlapSampleCount: 1
        ) == 1
    )
}

@Test
func transcriptDeduplicatorRejectsEmptyExactAndNearDuplicates() throws {
    var deduplicator = TranscriptDeduplicator()

    #expect(deduplicator.process(Transcript(text: "   ", timestamp: 0)) == nil)

    let processedFirst = deduplicator.process(Transcript(text: "Hello, world!", timestamp: 1))
    let first = try #require(processedFirst)
    #expect(first.text == "Hello, world!")
    #expect(deduplicator.process(Transcript(text: " hello world ", timestamp: 2)) == nil)
    #expect(deduplicator.process(Transcript(text: "Hello worlds", timestamp: 3)) == nil)
    #expect(deduplicator.suppressedCount == 3)
}

@Test
func transcriptDeduplicatorTrimsWindowOverlap() throws {
    var deduplicator = TranscriptDeduplicator()
    _ = deduplicator.process(Transcript(text: "Welcome to the live stream", timestamp: 1))

    let processedNext = deduplicator.process(
        Transcript(text: "the live stream today we discuss Swift", timestamp: 2)
    )
    let next = try #require(processedNext)

    #expect(next.text == "today we discuss Swift")
    #expect(next.timestamp == 2)
}

@Test
func transcriptDeduplicatorMapsNormalizedOverlapBackToRawTokens() throws {
    var deduplicator = TranscriptDeduplicator()
    _ = deduplicator.process(Transcript(text: "Welcome to the live stream", timestamp: 1))

    let processedNext = deduplicator.process(
        Transcript(text: "the ... live stream — today", timestamp: 2)
    )
    let next = try #require(processedNext)

    #expect(next.text == "— today")
    #expect(next.timestamp == 2)
}

private func chunk(duration: TimeInterval, timestamp: TimeInterval) -> AudioChunk {
    let sampleCount = Int((duration * 16_000).rounded())
    return AudioChunk(
        samples: Array(repeating: 0.05, count: sampleCount),
        sampleRate: 16_000,
        channelCount: 1,
        timestamp: timestamp,
        duration: duration
    )
}
