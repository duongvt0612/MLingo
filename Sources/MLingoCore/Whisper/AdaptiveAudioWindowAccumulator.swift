import Foundation

struct CapturedAudioChunk: Sendable {
    let chunk: AudioChunk
    let capturedAt: PerformanceInstant
}

struct TracedAudioWindow: Sendable {
    let chunk: AudioChunk
    let speechEnd: PerformanceInstant?
}

struct AdaptiveAudioWindowConfiguration: Equatable, Sendable {
    let minimumSpeechDuration: TimeInterval
    let preferredWindowDuration: TimeInterval
    let maximumWindowDuration: TimeInterval
    let silenceFlushDelay: TimeInterval
    let overlapDuration: TimeInterval
    let minimumQuietBoundaryDuration: TimeInterval

    init(
        minimumSpeechDuration: TimeInterval = 0.4,
        preferredWindowDuration: TimeInterval = 1.5,
        maximumWindowDuration: TimeInterval = 3.0,
        silenceFlushDelay: TimeInterval = 0.5,
        overlapDuration: TimeInterval = 0.4,
        minimumQuietBoundaryDuration: TimeInterval = 0.1
    ) {
        precondition(minimumSpeechDuration > 0)
        precondition(preferredWindowDuration >= minimumSpeechDuration)
        precondition(maximumWindowDuration >= preferredWindowDuration)
        precondition(silenceFlushDelay > 0)
        precondition(overlapDuration >= 0 && overlapDuration < maximumWindowDuration)
        precondition(minimumQuietBoundaryDuration > 0)

        self.minimumSpeechDuration = minimumSpeechDuration
        self.preferredWindowDuration = preferredWindowDuration
        self.maximumWindowDuration = maximumWindowDuration
        self.silenceFlushDelay = silenceFlushDelay
        self.overlapDuration = overlapDuration
        self.minimumQuietBoundaryDuration = minimumQuietBoundaryDuration
    }
}

struct AdaptiveAudioWindowAccumulator: Sendable {
    private struct CaptureSpan: Sendable {
        var sampleCount: Int
        let isSpeechLike: Bool
        let capturedAt: PerformanceInstant?
    }

    private let configuration: AdaptiveAudioWindowConfiguration
    private var samples: [Float] = []
    private var speechFlags: [Bool] = []
    private var captureSpans: [CaptureSpan] = []
    private var sampleRate: Double = 16_000
    private var channelCount = 1
    private var startTimestamp: TimeInterval = 0
    private var retainedOverlapSampleCount = 0

    init(configuration: AdaptiveAudioWindowConfiguration = .init()) {
        self.configuration = configuration
    }

    var bufferedDuration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    var bufferedTimestamp: TimeInterval {
        samples.isEmpty ? 0 : startTimestamp
    }

    mutating func append(_ chunk: AudioChunk) -> [AudioChunk] {
        appendTraced(chunk, capturedAt: nil).map(\.chunk)
    }

    mutating func appendTraced(
        _ chunk: AudioChunk,
        capturedAt: PerformanceInstant?
    ) -> [TracedAudioWindow] {
        guard chunk.sampleRate > 0, chunk.channelCount == 1, !chunk.samples.isEmpty else {
            return []
        }

        if samples.isEmpty {
            sampleRate = chunk.sampleRate
            channelCount = chunk.channelCount
            startTimestamp = chunk.timestamp
        } else if sampleRate != chunk.sampleRate
                    || channelCount != chunk.channelCount
                    || isTimestampDiscontinuous(chunk.timestamp)
        {
            reset()
            sampleRate = chunk.sampleRate
            channelCount = chunk.channelCount
            startTimestamp = chunk.timestamp
        }

        samples.append(contentsOf: chunk.samples)
        speechFlags.append(
            contentsOf: repeatElement(chunk.isSpeechLike, count: chunk.samples.count)
        )
        captureSpans.append(
            CaptureSpan(
                sampleCount: chunk.samples.count,
                isSpeechLike: chunk.isSpeechLike,
                capturedAt: capturedAt
            )
        )

        let preferredSampleCount = Int((configuration.preferredWindowDuration * sampleRate).rounded())
        let maximumSampleCount = Int((configuration.maximumWindowDuration * sampleRate).rounded())
        let overlapSampleCount = Int((configuration.overlapDuration * sampleRate).rounded())
        let minimumQuietSampleCount = max(
            1,
            Int((configuration.minimumQuietBoundaryDuration * sampleRate).rounded())
        )
        var windows: [TracedAudioWindow] = []

        while preferredSampleCount > 0, samples.count >= preferredSampleCount {
            if let boundarySampleCount = quietBoundarySampleCount(
                preferredSampleCount: preferredSampleCount,
                maximumSampleCount: maximumSampleCount,
                minimumQuietSampleCount: minimumQuietSampleCount
            ) {
                windows.append(
                    makeTracedWindow(
                        samples: Array(samples.prefix(boundarySampleCount)),
                        timestamp: startTimestamp,
                        sampleCount: boundarySampleCount
                    )
                )
                removeFirst(boundarySampleCount)
                retainedOverlapSampleCount = 0
                continue
            }

            guard maximumSampleCount > 0, samples.count >= maximumSampleCount else {
                break
            }

            guard hasMinimumNewSpeech(upTo: maximumSampleCount) else {
                removeFirst(maximumSampleCount)
                retainedOverlapSampleCount = 0
                continue
            }

            windows.append(
                makeTracedWindow(
                    samples: Array(samples.prefix(maximumSampleCount)),
                    timestamp: startTimestamp,
                    sampleCount: maximumSampleCount
                )
            )

            let retainedStartIndex = Self.retainedStartIndex(
                maximumSampleCount: maximumSampleCount,
                overlapSampleCount: overlapSampleCount
            )
            removeFirst(retainedStartIndex)
            retainedOverlapSampleCount = min(overlapSampleCount, samples.count)
        }

        return windows
    }

    private func isTimestampDiscontinuous(_ timestamp: TimeInterval) -> Bool {
        let expectedTimestamp = startTimestamp + Double(samples.count) / sampleRate
        let tolerance = 1 / sampleRate
        return !timestamp.isFinite || abs(timestamp - expectedTimestamp) > tolerance
    }

    static func retainedStartIndex(
        maximumSampleCount: Int,
        overlapSampleCount: Int
    ) -> Int {
        max(maximumSampleCount - overlapSampleCount, 1)
    }

    mutating func flushForSilence() -> AudioChunk? {
        flushForSilenceTraced()?.chunk
    }

    mutating func flushForSilenceTraced() -> TracedAudioWindow? {
        defer { reset() }
        let newSpeechSampleCount = speechFlags
            .dropFirst(retainedOverlapSampleCount)
            .lazy
            .filter { $0 }
            .count
        let newSpeechDuration = Double(newSpeechSampleCount) / sampleRate
        guard newSpeechDuration >= configuration.minimumSpeechDuration else {
            return nil
        }

        return makeTracedWindow(
            samples: samples,
            timestamp: startTimestamp,
            sampleCount: samples.count
        )
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        speechFlags.removeAll(keepingCapacity: true)
        captureSpans.removeAll(keepingCapacity: true)
        startTimestamp = 0
        retainedOverlapSampleCount = 0
    }

    private func quietBoundarySampleCount(
        preferredSampleCount: Int,
        maximumSampleCount: Int,
        minimumQuietSampleCount: Int
    ) -> Int? {
        let lookbackSampleCount = Int((configuration.overlapDuration * sampleRate).rounded())
        let minimumSpeechSampleCount = Int(
            (configuration.minimumSpeechDuration * sampleRate).rounded()
        )
        let lowerBound = max(
            minimumSpeechSampleCount,
            preferredSampleCount - lookbackSampleCount
        )
        let upperBound = min(samples.count, maximumSampleCount)
        guard lowerBound < upperBound else { return nil }

        var quietSampleCount = 0
        let newSpeechStartIndex = min(retainedOverlapSampleCount, lowerBound)
        var newSpeechSampleCount = speechFlags[newSpeechStartIndex..<lowerBound]
            .lazy
            .filter { $0 }
            .count
        for index in lowerBound..<upperBound {
            if speechFlags[index] {
                quietSampleCount = 0
                if index >= retainedOverlapSampleCount {
                    newSpeechSampleCount += 1
                }
            } else {
                quietSampleCount += 1
                if quietSampleCount >= minimumQuietSampleCount,
                   newSpeechSampleCount >= minimumSpeechSampleCount
                {
                    return index + 1
                }
            }
        }
        return nil
    }

    private func hasMinimumNewSpeech(upTo sampleCount: Int) -> Bool {
        let lowerBound = min(retainedOverlapSampleCount, speechFlags.count)
        let upperBound = min(sampleCount, speechFlags.count)
        guard lowerBound < upperBound else { return false }
        let newSpeechSampleCount = speechFlags[lowerBound..<upperBound]
            .lazy
            .filter { $0 }
            .count
        let minimumSpeechSampleCount = Int(
            (configuration.minimumSpeechDuration * sampleRate).rounded()
        )
        return newSpeechSampleCount >= minimumSpeechSampleCount
    }

    private mutating func removeFirst(_ count: Int) {
        samples.removeFirst(count)
        speechFlags.removeFirst(count)
        var remaining = count
        while remaining > 0, !captureSpans.isEmpty {
            if captureSpans[0].sampleCount <= remaining {
                remaining -= captureSpans[0].sampleCount
                captureSpans.removeFirst()
            } else {
                captureSpans[0].sampleCount -= remaining
                remaining = 0
            }
        }
        startTimestamp += Double(count) / sampleRate
    }

    private func makeTracedWindow(
        samples: [Float],
        timestamp: TimeInterval,
        sampleCount: Int
    ) -> TracedAudioWindow {
        TracedAudioWindow(
            chunk: AudioChunk(
                samples: samples,
                sampleRate: sampleRate,
                channelCount: channelCount,
                timestamp: timestamp,
                duration: Double(samples.count) / sampleRate
            ),
            speechEnd: lastSpeechCaptureInstant(inFirst: sampleCount)
        )
    }

    private func lastSpeechCaptureInstant(inFirst sampleCount: Int) -> PerformanceInstant? {
        var remaining = sampleCount
        var lastSpeechInstant: PerformanceInstant?
        for span in captureSpans where remaining > 0 {
            let includedCount = min(remaining, span.sampleCount)
            if includedCount > 0, span.isSpeechLike, let capturedAt = span.capturedAt {
                lastSpeechInstant = capturedAt
            }
            remaining -= includedCount
        }
        return lastSpeechInstant
    }
}
