@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import MLingoCore

@Test
func mlxWhisperTranscribesJFKFixture() async throws {
    guard ProcessInfo.processInfo.environment["MLINGO_RUN_MLX_INTEGRATION"] == "1" else {
        return
    }

    let fixtureURL = try #require(
        Bundle.module.url(
            forResource: "jfk",
            withExtension: "flac",
            subdirectory: "Fixtures"
        )
    )
    let chunk = try loadMonoAudioFixture(from: fixtureURL)
    let engine = MLXWhisperEngine()
    try await engine.loadModel(named: "mlx-community/whisper-base-mlx")
    let transcript = try await engine.transcribe(chunk, language: "English")
    let text = try #require(transcript?.text.lowercased())

    #expect(text.contains("ask not what your country can do for you"))
}

private func loadMonoAudioFixture(from url: URL) throws -> AudioChunk {
    let file = try AVAudioFile(forReading: url)
    let frameCount = AVAudioFrameCount(file.length)
    let sourceFormat = file.processingFormat
    let sourceBuffer = try #require(
        AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
    )
    try file.read(into: sourceBuffer)

    let targetFormat = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )
    )
    let converter = try #require(AVAudioConverter(from: sourceFormat, to: targetFormat))
    let capacity = AVAudioFrameCount(
        ceil(Double(sourceBuffer.frameLength) * 16_000 / sourceFormat.sampleRate)
    ) + 1
    let outputBuffer = try #require(
        AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
    )
    let inputProvider = AudioConverterInputProvider(buffer: sourceBuffer)
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
        inputProvider.next(status: inputStatus)
    }
    if status == .error {
        throw conversionError ?? MLingoError.captureFailed("Could not convert JFK fixture")
    }

    let channelData = try #require(outputBuffer.floatChannelData)
    let samples = Array(
        UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        )
    )

    return AudioChunk(
        samples: samples,
        sampleRate: targetFormat.sampleRate,
        channelCount: 1,
        timestamp: 0,
        duration: Double(outputBuffer.frameLength) / targetFormat.sampleRate
    )
}

private final class AudioConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var hasProvidedBuffer = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !hasProvidedBuffer else {
            status.pointee = .endOfStream
            return nil
        }
        hasProvidedBuffer = true
        status.pointee = .haveData
        return buffer
    }
}
