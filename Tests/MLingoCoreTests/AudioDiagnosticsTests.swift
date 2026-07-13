import Foundation
import Testing
@testable import MLingoCore

@Test
func audioLevelAnalyzerComputesRMSPeakAndSpeechFlag() {
    let level = AudioLevelAnalyzer.analyze(
        samples: [0.0, 0.03, -0.03, 0.0],
        vadThreshold: 0.015
    )

    #expect(abs(level.rms - 0.0212) < 0.001)
    #expect(abs(level.peak - 0.03) < 0.001)
    #expect(level.isSpeechLike)
}

@Test
func audioLevelAnalyzerDropsSilenceBelowThreshold() {
    let level = AudioLevelAnalyzer.analyze(
        samples: [0.001, -0.001, 0.0],
        vadThreshold: 0.015
    )

    #expect(level.rms < 0.015)
    #expect(!level.isSpeechLike)
}

@Test
func diagnosticsAccumulatorTracksChunkCounters() {
    var accumulator = AudioCaptureDiagnosticsAccumulator()
    let chunk = AudioChunk(
        samples: [0.02, -0.02],
        sampleRate: 16_000,
        channelCount: 1,
        timestamp: 1,
        duration: 0.02
    )
    let level = AudioLevelAnalyzer.analyze(samples: chunk.samples)

    _ = accumulator.update(state: .running)
    _ = accumulator.recordCapturedChunk(chunk, level: level)
    _ = accumulator.recordSpeechLikeChunk()
    _ = accumulator.recordDroppedChunk()
    _ = accumulator.recordEmptyChunk()

    let diagnostics = accumulator.diagnostics
    #expect(diagnostics.state == .running)
    #expect(diagnostics.capturedChunkCount == 1)
    #expect(diagnostics.speechLikeChunkCount == 1)
    #expect(diagnostics.droppedChunkCount == 1)
    #expect(diagnostics.emptyChunkCount == 1)
    #expect(diagnostics.sampleRate == 16_000)
    #expect(diagnostics.channelCount == 1)
}
