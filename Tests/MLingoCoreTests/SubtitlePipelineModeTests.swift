import Foundation
import Testing
@testable import MLingoCore

@Test @MainActor
func transcriptionOnlyEmitsTranscriptWithoutTranslationOrOverlay() async throws {
    let audio = PipelineAudioEngine()
    let whisper = PipelineWhisperEngine(text: "A real transcript")
    let translation = PipelineTranslationEngine()
    let overlay = PipelineOverlayEngine()
    let settings = PipelineSettingsStore()
    let transcriptRecorder = PipelineTranscriptRecorder()
    let diagnosticsRecorder = PipelineDiagnosticsRecorder()
    let pipeline = SubtitlePipeline(
        audioEngine: audio,
        whisperEngine: whisper,
        translationEngine: translation,
        overlayEngine: overlay,
        settingsStore: settings
    )

    await pipeline.start(
        mode: .transcriptionOnly,
        onError: { _ in },
        onTranscript: { transcript in
            await transcriptRecorder.append(transcript)
        },
        onWhisperDiagnostics: { diagnostics in
            await diagnosticsRecorder.append(diagnostics)
        }
    )
    audio.yield(pipelineAudioChunk(timestamp: 5))

    try await pipelineEventually {
        let transcriptCount = await transcriptRecorder.count
        let diagnosticsCount = await diagnosticsRecorder.count
        return transcriptCount == 1 && diagnosticsCount > 0
    }

    #expect(await translation.callCount == 0)
    #expect(overlay.showCount == 0)
    #expect(overlay.updateCount == 0)
    #expect(await diagnosticsRecorder.latest.modelState == .ready)
    await pipeline.stop()
}

@Test @MainActor
func translationModePreservesTranslationAndOverlayFlow() async throws {
    let audio = PipelineAudioEngine()
    let whisper = PipelineWhisperEngine(text: "Translate this")
    let translation = PipelineTranslationEngine()
    let overlay = PipelineOverlayEngine()
    let settings = PipelineSettingsStore()
    let pipeline = SubtitlePipeline(
        audioEngine: audio,
        whisperEngine: whisper,
        translationEngine: translation,
        overlayEngine: overlay,
        settingsStore: settings
    )

    await pipeline.start(
        mode: .translation,
        onError: { _ in }
    )
    audio.yield(pipelineAudioChunk(timestamp: 8))

    try await pipelineEventually {
        await overlay.updateCount == 1
    }

    #expect(await translation.callCount == 1)
    #expect(overlay.showCount == 1)
    #expect(overlay.lastSubtitle?.original == "Translate this")
    await pipeline.stop()
    #expect(overlay.hideCount == 1)
}

@Test @MainActor
func audioDiagnosticsSkipStaleSnapshotsWhenUIIsBusy() async throws {
    let audio = PipelineAudioEngine()
    let recorder = SlowAudioDiagnosticsRecorder()
    let pipeline = SubtitlePipeline(
        audioEngine: audio,
        whisperEngine: PipelineWhisperEngine(text: "unused"),
        translationEngine: PipelineTranslationEngine(),
        overlayEngine: PipelineOverlayEngine(),
        settingsStore: PipelineSettingsStore()
    )

    await pipeline.start(
        mode: .transcriptionOnly,
        onError: { _ in },
        onAudioDiagnostics: { diagnostics in
            await recorder.append(diagnostics)
        }
    )

    audio.yieldDiagnostics(capturedChunkCount: 1)
    try await pipelineEventually {
        await recorder.isHandlingFirstSnapshot
    }

    audio.yieldDiagnostics(capturedChunkCount: 2)
    audio.yieldDiagnostics(capturedChunkCount: 3)
    await recorder.releaseFirstSnapshot()

    try await pipelineEventually {
        await recorder.capturedChunkCounts.count == 2
    }
    #expect(await recorder.capturedChunkCounts == [1, 3])
    await pipeline.stop()
}

private final class PipelineAudioEngine: AudioEngineProtocol, @unchecked Sendable {
    let chunks: AsyncStream<AudioChunk>
    let diagnostics: AsyncStream<AudioCaptureDiagnostics>
    private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    private let diagnosticsContinuation: AsyncStream<AudioCaptureDiagnostics>.Continuation

    init() {
        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (diagnostics, diagnosticsContinuation) = AsyncStream.makeStream(
            of: AudioCaptureDiagnostics.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.chunks = chunks
        self.diagnostics = diagnostics
        self.chunkContinuation = chunkContinuation
        self.diagnosticsContinuation = diagnosticsContinuation
    }

    var state: AudioCaptureState { get async { .running } }

    func start() async throws {}
    func stop() async {}

    func yield(_ chunk: AudioChunk) {
        chunkContinuation.yield(chunk)
    }

    func yieldDiagnostics(capturedChunkCount: Int) {
        diagnosticsContinuation.yield(
            AudioCaptureDiagnostics(
                capturedChunkCount: capturedChunkCount,
                state: .running
            )
        )
    }
}

private actor PipelineWhisperEngine: WhisperEngineProtocol {
    let text: String

    init(text: String) {
        self.text = text
    }

    func loadModel(named modelName: String) async throws {}

    func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript? {
        Transcript(text: text, timestamp: chunk.timestamp)
    }
}

private actor PipelineTranslationEngine: TranslationEngineProtocol {
    private(set) var callCount = 0

    func translate(_ transcript: Transcript, settings: AppSettings) async throws -> SubtitleItem {
        callCount += 1
        return SubtitleItem(
            original: transcript.text,
            translated: "Bản dịch",
            start: transcript.timestamp,
            end: transcript.timestamp + 2
        )
    }
}

@MainActor
private final class PipelineOverlayEngine: OverlayEngineProtocol {
    private(set) var showCount = 0
    private(set) var updateCount = 0
    private(set) var hideCount = 0
    private(set) var lastSubtitle: SubtitleItem?

    func show() { showCount += 1 }

    func update(with subtitle: SubtitleItem, settings: AppSettings) {
        updateCount += 1
        lastSubtitle = subtitle
    }

    func hide() { hideCount += 1 }
}

private actor PipelineSettingsStore: SettingsStoreProtocol {
    private var settings = AppSettings()

    func load() async throws -> AppSettings { settings }
    func save(_ settings: AppSettings) async throws { self.settings = settings }
}

private actor PipelineTranscriptRecorder {
    private var values: [Transcript] = []
    var count: Int { values.count }

    func append(_ transcript: Transcript) {
        values.append(transcript)
    }
}

private actor PipelineDiagnosticsRecorder {
    private var values: [WhisperDiagnostics] = []
    var count: Int { values.count }
    var latest: WhisperDiagnostics { values.last ?? WhisperDiagnostics() }

    func append(_ diagnostics: WhisperDiagnostics) {
        values.append(diagnostics)
    }
}

private actor SlowAudioDiagnosticsRecorder {
    private var values: [AudioCaptureDiagnostics] = []
    private var firstSnapshotContinuation: CheckedContinuation<Void, Never>?
    private(set) var isHandlingFirstSnapshot = false

    var capturedChunkCounts: [Int] {
        values.map(\.capturedChunkCount)
    }

    func append(_ diagnostics: AudioCaptureDiagnostics) async {
        if values.isEmpty {
            isHandlingFirstSnapshot = true
            await withCheckedContinuation { continuation in
                firstSnapshotContinuation = continuation
            }
        }
        values.append(diagnostics)
    }

    func releaseFirstSnapshot() {
        firstSnapshotContinuation?.resume()
        firstSnapshotContinuation = nil
    }
}

private func pipelineEventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Condition was not met before timeout")
}

private func pipelineAudioChunk(timestamp: TimeInterval) -> AudioChunk {
    AudioChunk(
        samples: Array(repeating: 0.05, count: 48_000),
        sampleRate: 16_000,
        channelCount: 1,
        timestamp: timestamp,
        duration: 3
    )
}
