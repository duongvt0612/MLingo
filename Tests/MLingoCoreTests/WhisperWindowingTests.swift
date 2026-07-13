import Foundation
import Testing
@testable import MLingoCore

@Test
func adaptiveWindowFlushesShortSpeechAfterSilence() throws {
    var accumulator = AdaptiveAudioWindowAccumulator()

    #expect(accumulator.append(chunk(duration: 0.2, timestamp: 10)).isEmpty)
    #expect(accumulator.append(chunk(duration: 0.25, timestamp: 10.2)).isEmpty)

    let window = try #require(accumulator.flushForSilence())
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
func adaptiveWindowFlushesAtHardLimitAndRetainsOverlap() throws {
    var accumulator = AdaptiveAudioWindowAccumulator()

    let emitted = accumulator.append(chunk(duration: 3.2, timestamp: 20))

    let window = try #require(emitted.first)
    #expect(emitted.count == 1)
    #expect(abs(window.duration - 3.0) < 0.001)
    #expect(window.timestamp == 20)
    #expect(window.samples.count == 48_000)
    #expect(abs(accumulator.bufferedDuration - 0.6) < 0.001)
    #expect(abs(accumulator.bufferedTimestamp - 22.6) < 0.001)
}

@Test
func transcriptDeduplicatorRejectsEmptyExactAndNearDuplicates() throws {
    var deduplicator = TranscriptDeduplicator()

    #expect(deduplicator.process(Transcript(text: "   ", timestamp: 0)) == nil)

    let first = try #require(deduplicator.process(Transcript(text: "Hello, world!", timestamp: 1)))
    #expect(first.text == "Hello, world!")
    #expect(deduplicator.process(Transcript(text: " hello world ", timestamp: 2)) == nil)
    #expect(deduplicator.process(Transcript(text: "Hello worlds", timestamp: 3)) == nil)
    #expect(deduplicator.suppressedCount == 3)
}

@Test
func transcriptDeduplicatorTrimsWindowOverlap() throws {
    var deduplicator = TranscriptDeduplicator()
    _ = deduplicator.process(Transcript(text: "Welcome to the live stream", timestamp: 1))

    let next = try #require(
        deduplicator.process(Transcript(text: "the live stream today we discuss Swift", timestamp: 2))
    )

    #expect(next.text == "today we discuss Swift")
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
