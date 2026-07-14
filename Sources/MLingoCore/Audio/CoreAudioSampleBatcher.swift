import Foundation

struct CoreAudioSampleBatch: Equatable, Sendable {
    let samples: [Float]
    let sampleRate: Double
    let timestamp: TimeInterval
}

struct CoreAudioSampleBatcher: Sendable {
    private let targetDuration: TimeInterval
    private var samples: [Float] = []
    private var sampleRate: Double = 0
    private var startTimestamp: TimeInterval = 0

    init(targetDuration: TimeInterval = 0.1) {
        precondition(targetDuration > 0)
        self.targetDuration = targetDuration
    }

    var bufferedSampleCount: Int { samples.count }

    mutating func append(
        samples newSamples: [Float],
        sampleRate newSampleRate: Double,
        timestamp: TimeInterval
    ) -> [CoreAudioSampleBatch] {
        guard newSampleRate > 0, !newSamples.isEmpty else { return [] }

        var batches: [CoreAudioSampleBatch] = []
        if !samples.isEmpty, sampleRate != newSampleRate, let pendingBatch = flush() {
            batches.append(pendingBatch)
        }
        if samples.isEmpty {
            sampleRate = newSampleRate
            startTimestamp = timestamp
        }

        samples.append(contentsOf: newSamples)
        let targetSampleCount = max(1, Int((targetDuration * sampleRate).rounded()))
        while samples.count >= targetSampleCount {
            let batchSamples = Array(samples.prefix(targetSampleCount))
            batches.append(
                CoreAudioSampleBatch(
                    samples: batchSamples,
                    sampleRate: sampleRate,
                    timestamp: startTimestamp
                )
            )
            samples.removeFirst(targetSampleCount)
            startTimestamp += Double(targetSampleCount) / sampleRate
        }
        return batches
    }

    mutating func flush() -> CoreAudioSampleBatch? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }
        defer { reset() }
        return CoreAudioSampleBatch(
            samples: samples,
            sampleRate: sampleRate,
            timestamp: startTimestamp
        )
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        sampleRate = 0
        startTimestamp = 0
    }
}
