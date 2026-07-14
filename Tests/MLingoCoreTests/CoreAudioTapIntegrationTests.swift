import Foundation
import Testing
@testable import MLingoCore

@Test
func coreAudioTapCapturesMonoSixteenKilohertzAudio() async throws {
    guard ProcessInfo.processInfo.environment["MLINGO_RUN_CORE_AUDIO_INTEGRATION"] == "1" else {
        return
    }
    guard #available(macOS 14.2, *) else { return }

    let engine = CoreAudioTapEngine()
    do {
        try await engine.start()
        let chunk = try await firstCoreAudioChunk(from: engine.chunks)
        #expect(chunk.sampleRate == 16_000)
        #expect(chunk.channelCount == 1)
        #expect(!chunk.samples.isEmpty)
        await engine.stop()
    } catch {
        await engine.stop()
        throw error
    }
}

private func firstCoreAudioChunk(
    from stream: AsyncStream<AudioChunk>
) async throws -> AudioChunk {
    try await withThrowingTaskGroup(of: AudioChunk.self) { group in
        group.addTask {
            for await chunk in stream {
                return chunk
            }
            throw MLingoError.captureFailed("Core Audio stream ended before yielding audio")
        }
        group.addTask {
            try await Task.sleep(for: .seconds(10))
            throw MLingoError.captureFailed(
                "No speech-like system audio arrived within 10 seconds"
            )
        }
        let chunk = try await group.next()!
        group.cancelAll()
        return chunk
    }
}
