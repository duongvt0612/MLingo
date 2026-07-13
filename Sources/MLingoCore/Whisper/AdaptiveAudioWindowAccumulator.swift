import Foundation

struct AdaptiveAudioWindowConfiguration: Equatable, Sendable {
    let minimumSpeechDuration: TimeInterval
    let preferredWindowDuration: TimeInterval
    let maximumWindowDuration: TimeInterval
    let silenceFlushDelay: TimeInterval
    let overlapDuration: TimeInterval

    init(
        minimumSpeechDuration: TimeInterval = 0.4,
        preferredWindowDuration: TimeInterval = 1.5,
        maximumWindowDuration: TimeInterval = 3.0,
        silenceFlushDelay: TimeInterval = 0.5,
        overlapDuration: TimeInterval = 0.4
    ) {
        precondition(minimumSpeechDuration > 0)
        precondition(preferredWindowDuration >= minimumSpeechDuration)
        precondition(maximumWindowDuration >= preferredWindowDuration)
        precondition(silenceFlushDelay > 0)
        precondition(overlapDuration >= 0 && overlapDuration < maximumWindowDuration)

        self.minimumSpeechDuration = minimumSpeechDuration
        self.preferredWindowDuration = preferredWindowDuration
        self.maximumWindowDuration = maximumWindowDuration
        self.silenceFlushDelay = silenceFlushDelay
        self.overlapDuration = overlapDuration
    }
}

struct AdaptiveAudioWindowAccumulator: Sendable {
    private let configuration: AdaptiveAudioWindowConfiguration
    private var samples: [Float] = []
    private var sampleRate: Double = 16_000
    private var channelCount = 1
    private var startTimestamp: TimeInterval = 0

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

        let maximumSampleCount = Int((configuration.maximumWindowDuration * sampleRate).rounded())
        let overlapSampleCount = Int((configuration.overlapDuration * sampleRate).rounded())
        var windows: [AudioChunk] = []

        while maximumSampleCount > 0, samples.count >= maximumSampleCount {
            let windowSamples = Array(samples.prefix(maximumSampleCount))
            windows.append(makeChunk(samples: windowSamples, timestamp: startTimestamp))

            let retainedStartIndex = max(maximumSampleCount - overlapSampleCount, 0)
            samples.removeFirst(retainedStartIndex)
            startTimestamp += Double(retainedStartIndex) / sampleRate
        }

        return windows
    }

    mutating func flushForSilence() -> AudioChunk? {
        defer { reset() }
        guard bufferedDuration >= configuration.minimumSpeechDuration else {
            return nil
        }

        return makeChunk(samples: samples, timestamp: startTimestamp)
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        startTimestamp = 0
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
