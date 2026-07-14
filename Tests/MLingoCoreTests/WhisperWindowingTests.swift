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
func adaptiveWindowWaitsForHardLimitAndRetainsOverlapDuringContinuousSpeech() throws {
    var accumulator = AdaptiveAudioWindowAccumulator()

    let emitted = accumulator.append(chunk(duration: 3.2, timestamp: 20))

    #expect(emitted.count == 1)
    #expect(abs(emitted[0].duration - 3.0) < 0.001)
    #expect(emitted[0].timestamp == 20)
    #expect(abs(accumulator.bufferedDuration - 0.6) < 0.001)
    #expect(abs(accumulator.bufferedTimestamp - 22.6) < 0.001)
}

@Test
func adaptiveWindowCutsAtQuietBoundaryWithoutRetainingOverlap() throws {
    var accumulator = AdaptiveAudioWindowAccumulator()

    #expect(accumulator.append(chunk(duration: 1.4, timestamp: 20)).isEmpty)
    let firstWindows = accumulator.append(
        chunk(duration: 0.2, timestamp: 21.4, isSpeechLike: false)
    )
    let first = try #require(firstWindows.first)

    #expect(firstWindows.count == 1)
    #expect(abs(first.duration - 1.5) < 0.001)
    #expect(abs(accumulator.bufferedTimestamp - 21.5) < 0.001)

    #expect(accumulator.append(chunk(duration: 1.4, timestamp: 21.6)).isEmpty)
    let secondWindows = accumulator.append(
        chunk(duration: 0.2, timestamp: 23, isSpeechLike: false)
    )
    let second = try #require(secondWindows.first)

    #expect(abs(second.timestamp - (first.timestamp + first.duration)) < 0.001)
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
        Transcript(text: "the live stream today we discuss Swift", timestamp: 2),
        audioOverlapDuration: 0.4
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
        Transcript(text: "the ... live stream — today", timestamp: 2),
        audioOverlapDuration: 0.4
    )
    let next = try #require(processedNext)

    #expect(next.text == "— today")
    #expect(next.timestamp == 2)
}

@Test
func transcriptDeduplicatorTrimsFuzzyOverlapFromOverlappingAudio() throws {
    var deduplicator = TranscriptDeduplicator()
    _ = deduplicator.process(
        Transcript(text: "We need a very reliable transcript", timestamp: 1)
    )

    let processedNext = deduplicator.process(
        Transcript(
            text: "a really reliable transcript before translation starts",
            timestamp: 2
        ),
        audioOverlapDuration: 0.4
    )
    let next = try #require(processedNext)

    #expect(next.text == "before translation starts")
}

@Test
func transcriptDeduplicatorTrimsFuzzyOverlapWhenLeadingWordIsRedecoded() throws {
    var deduplicator = TranscriptDeduplicator()
    _ = deduplicator.process(
        Transcript(text: "This is a good solution", timestamp: 1)
    )

    let processedNext = deduplicator.process(
        Transcript(text: "It is a good solution for translation", timestamp: 2),
        audioOverlapDuration: 0.4
    )
    let next = try #require(processedNext)

    #expect(next.text == "for translation")
}

@Test
func transcriptDeduplicatorTrimsSingleRepeatedTokenOnlyForOverlappingAudio() throws {
    var deduplicator = TranscriptDeduplicator()
    _ = deduplicator.process(Transcript(text: "Please continue", timestamp: 1))

    let processedNext = deduplicator.process(
        Transcript(text: "continue with the next point", timestamp: 2),
        audioOverlapDuration: 0.4
    )
    let next = try #require(processedNext)

    #expect(next.text == "with the next point")
}

@Test
func transcriptDeduplicatorPreservesRepeatedSpeechWithoutAudioOverlap() throws {
    var deduplicator = TranscriptDeduplicator()
    _ = deduplicator.process(
        Transcript(text: "The speaker said we should continue", timestamp: 1)
    )

    let processedNext = deduplicator.process(
        Transcript(text: "we should continue because this is important", timestamp: 2),
        audioOverlapDuration: 0
    )
    let next = try #require(processedNext)

    #expect(next.text == "we should continue because this is important")
}

private func chunk(
    duration: TimeInterval,
    timestamp: TimeInterval,
    isSpeechLike: Bool = true
) -> AudioChunk {
    let sampleCount = Int((duration * 16_000).rounded())
    return AudioChunk(
        samples: Array(repeating: 0.05, count: sampleCount),
        sampleRate: 16_000,
        channelCount: 1,
        timestamp: timestamp,
        duration: duration,
        isSpeechLike: isSpeechLike
    )
}
