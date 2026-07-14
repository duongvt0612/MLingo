import Foundation

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
    private let configuration: AdaptiveAudioWindowConfiguration
    private var samples: [Float] = []
    private var speechFlags: [Bool] = []
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
        guard chunk.sampleRate > 0, chunk.channelCount == 1, !chunk.samples.isEmpty else {
            return []
        }

        if samples.isEmpty {
            sampleRate = chunk.sampleRate
            channelCount = chunk.channelCount
            startTimestamp = chunk.timestamp
        } else if sampleRate != chunk.sampleRate || channelCount != chunk.channelCount {
            reset()
            sampleRate = chunk.sampleRate
            channelCount = chunk.channelCount
            startTimestamp = chunk.timestamp
        }

        samples.append(contentsOf: chunk.samples)
        speechFlags.append(
            contentsOf: repeatElement(chunk.isSpeechLike, count: chunk.samples.count)
        )

        let preferredSampleCount = Int((configuration.preferredWindowDuration * sampleRate).rounded())
        let maximumSampleCount = Int((configuration.maximumWindowDuration * sampleRate).rounded())
        let overlapSampleCount = Int((configuration.overlapDuration * sampleRate).rounded())
        let minimumQuietSampleCount = max(
            1,
            Int((configuration.minimumQuietBoundaryDuration * sampleRate).rounded())
        )
        var windows: [AudioChunk] = []

        while preferredSampleCount > 0, samples.count >= preferredSampleCount {
            if let boundarySampleCount = quietBoundarySampleCount(
                preferredSampleCount: preferredSampleCount,
                maximumSampleCount: maximumSampleCount,
                minimumQuietSampleCount: minimumQuietSampleCount
            ) {
                windows.append(
                    makeChunk(
                        samples: Array(samples.prefix(boundarySampleCount)),
                        timestamp: startTimestamp
                    )
                )
                removeFirst(boundarySampleCount)
                retainedOverlapSampleCount = 0
                continue
            }

            guard maximumSampleCount > 0, samples.count >= maximumSampleCount else {
                break
            }

            windows.append(
                makeChunk(
                    samples: Array(samples.prefix(maximumSampleCount)),
                    timestamp: startTimestamp
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

    static func retainedStartIndex(
        maximumSampleCount: Int,
        overlapSampleCount: Int
    ) -> Int {
        max(maximumSampleCount - overlapSampleCount, 1)
    }

    mutating func flushForSilence() -> AudioChunk? {
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

        return makeChunk(samples: samples, timestamp: startTimestamp)
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        speechFlags.removeAll(keepingCapacity: true)
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
        for index in lowerBound..<upperBound {
            if speechFlags[index] {
                quietSampleCount = 0
            } else {
                quietSampleCount += 1
                if quietSampleCount >= minimumQuietSampleCount {
                    return index + 1
                }
            }
        }
        return nil
    }

    private mutating func removeFirst(_ count: Int) {
        samples.removeFirst(count)
        speechFlags.removeFirst(count)
        startTimestamp += Double(count) / sampleRate
    }

    private func makeChunk(samples: [Float], timestamp: TimeInterval) -> AudioChunk {
        AudioChunk(
            samples: samples,
            sampleRate: sampleRate,
            channelCount: channelCount,
            timestamp: timestamp,
            duration: Double(samples.count) / sampleRate
        )
    }
}
