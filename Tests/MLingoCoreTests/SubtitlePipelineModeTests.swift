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
        audioEngineFactory: PipelineAudioEngineFactory(engines: [audio]),
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
func pipelineUsesCaptureBackendFromSettings() async {
    let audio = PipelineAudioEngine()
    let factory = PipelineAudioEngineFactory(engines: [audio])
    let pipeline = SubtitlePipeline(
        audioEngineFactory: factory,
        whisperEngine: PipelineWhisperEngine(text: "unused"),
        translationEngine: PipelineTranslationEngine(),
        overlayEngine: PipelineOverlayEngine(),
        settingsStore: PipelineSettingsStore(
            settings: AppSettings(audioCaptureBackend: .screenCaptureKit)
        )
    )

    await pipeline.start(mode: .transcriptionOnly, onError: { _ in })

    #expect(factory.requestedBackends == [.screenCaptureKit])
    await pipeline.stop()
}

@Test @MainActor
func pipelineReportsAudioStartupFailure() async {
    let audio = PipelineAudioEngine(startError: MLingoError.noAudioSource)
    let errors = PipelineMessageRecorder()
    let pipeline = SubtitlePipeline(
        audioEngineFactory: PipelineAudioEngineFactory(engines: [audio]),
        whisperEngine: PipelineWhisperEngine(text: "unused"),
        translationEngine: PipelineTranslationEngine(),
        overlayEngine: PipelineOverlayEngine(),
        settingsStore: PipelineSettingsStore()
    )

    let started = await pipeline.start(
        mode: .transcriptionOnly,
        onError: { errors.append($0) }
    )

    #expect(!started)
    #expect(errors.latest == MLingoError.noAudioSource.localizedDescription)
}

@Test @MainActor
func translationModePreservesTranslationAndOverlayFlow() async throws {
    let audio = PipelineAudioEngine()
    let whisper = PipelineWhisperEngine(text: "Translate this")
    let translation = PipelineTranslationEngine()
    let overlay = PipelineOverlayEngine()
    let settings = PipelineSettingsStore()
    let pipeline = SubtitlePipeline(
        audioEngineFactory: PipelineAudioEngineFactory(engines: [audio]),
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
func performanceDiagnosticsCompleteAndRemainAvailableAfterTranslationStops() async throws {
    let audio = PipelineAudioEngine()
    let overlay = PipelineOverlayEngine()
    let recorder = PipelinePerformanceRecorder()
    let pipeline = SubtitlePipeline(
        audioEngineFactory: PipelineAudioEngineFactory(engines: [audio]),
        whisperEngine: PipelineWhisperEngine(text: "Measured transcript"),
        translationEngine: PipelineTranslationEngine(),
        overlayEngine: overlay,
        settingsStore: PipelineSettingsStore()
    )

    await pipeline.start(
        mode: .translation,
        onError: { _ in },
        onPerformanceDiagnostics: { diagnostics in
            await recorder.append(diagnostics)
        }
    )
    audio.yield(pipelineAudioChunk(timestamp: 4))

    try await pipelineEventually(timeout: .seconds(2)) {
        await recorder.latest.totalLatency.sampleCount == 1
    }
    let completed = await recorder.latest
    #expect(completed.whisperDecodeLatency.sampleCount == 1)
    #expect(completed.translationRequestLatency.sampleCount == 1)
    #expect(completed.overlayRenderLatency.sampleCount == 1)
    #expect(completed.totalLatency.latest != nil)
    #expect(completed.residentMemoryBytes != nil)

    await pipeline.stop()
    let stopped = await recorder.latest
    #expect(stopped.totalLatency == completed.totalLatency)
    #expect(stopped.whisperDecodeLatency == completed.whisperDecodeLatency)
    #expect(stopped.translationRequestLatency == completed.translationRequestLatency)
    #expect(stopped.overlayRenderLatency == completed.overlayRenderLatency)
    #expect(stopped.sessionDuration >= completed.sessionDuration)
}

@Test @MainActor
func pipelineProxiesOverlayCommandsOnlyDuringTranslationSession() async {
    let audio = PipelineAudioEngine()
    let overlay = PipelineOverlayEngine()
    let settings = AppSettings(
        subtitleFontSize: 32,
        subtitleBackgroundOpacity: 0.72
    )
    let pipeline = SubtitlePipeline(
        audioEngineFactory: PipelineAudioEngineFactory(engines: [audio]),
        whisperEngine: PipelineWhisperEngine(text: "unused"),
        translationEngine: PipelineTranslationEngine(),
        overlayEngine: overlay,
        settingsStore: PipelineSettingsStore(settings: settings)
    )

    pipeline.setOverlayVisible(false)
    pipeline.beginOverlayRepositioning()
    pipeline.endOverlayRepositioning()
    pipeline.resetOverlayPosition()
    pipeline.selectOverlayDisplay(.display(id: "external"))

    #expect(overlay.commandCount == 1)

    let started = await pipeline.start(mode: .translation, onError: { _ in })
    #expect(started)
    #expect(overlay.lastShownSettings == settings)

    pipeline.setOverlayVisible(false)
    pipeline.beginOverlayRepositioning()
    pipeline.endOverlayRepositioning()
    pipeline.resetOverlayPosition()
    pipeline.selectOverlayDisplay(.display(id: "external"))

    #expect(overlay.commandCount == 6)

    await pipeline.stop()
    #expect(overlay.hideCount == 1)
}

@Test @MainActor
func translationModeReceivesOnlyTextAfterFuzzyOverlap() async throws {
    let audio = PipelineAudioEngine()
    let whisper = PipelineScriptedWhisperEngine(texts: [
        "We need a very reliable transcript",
        "a really reliable transcript before translation starts",
    ])
    let translation = PipelineTranslationEngine()
    let pipeline = SubtitlePipeline(
        audioEngineFactory: PipelineAudioEngineFactory(engines: [audio]),
        whisperEngine: whisper,
        translationEngine: translation,
        overlayEngine: PipelineOverlayEngine(),
        settingsStore: PipelineSettingsStore()
    )

    await pipeline.start(mode: .translation, onError: { _ in })
    audio.yield(pipelineAudioChunk(timestamp: 0))
    try await pipelineEventually { await translation.callCount == 1 }
    audio.yield(pipelineAudioChunk(timestamp: 3))
    try await pipelineEventually { await translation.callCount == 2 }

    #expect(await translation.originalTexts == [
        "We need a very reliable transcript",
        "before translation starts",
    ])
    await pipeline.stop()
}

@Test @MainActor
func translationWorkerDoesNotBlockFollowingTranscripts() async throws {
    let audio = PipelineAudioEngine()
    let whisper = PipelineScriptedWhisperEngine(texts: ["First line", "Second line"])
    let translation = BlockingPipelineTranslationEngine()
    let overlay = PipelineOverlayEngine()
    let transcripts = PipelineTranscriptRecorder()
    let pipeline = SubtitlePipeline(
        audioEngineFactory: PipelineAudioEngineFactory(engines: [audio]),
        whisperEngine: whisper,
        translationEngine: translation,
        overlayEngine: overlay,
        settingsStore: PipelineSettingsStore()
    )

    await pipeline.start(
        mode: .translation,
        onError: { _ in },
        onTranscript: { transcript in await transcripts.append(transcript) }
    )
    audio.yield(pipelineAudioChunk(timestamp: 0))
    try await pipelineEventually { await translation.callCount == 1 }

    audio.yield(pipelineAudioChunk(timestamp: 3))
    try await pipelineEventually { await transcripts.count == 2 }
    #expect(await translation.callCount == 1)

    await translation.releaseFirst()
    try await pipelineEventually { await overlay.updateCount == 2 }
    #expect(await translation.originalTexts == ["First line", "Second line"])
    await pipeline.stop()
}

@Test @MainActor
func translationWorkerCapturesTwoPreviousTranscriptsAsContext() async throws {
    let audio = PipelineAudioEngine()
    let translation = PipelineTranslationEngine()
    let pipeline = SubtitlePipeline(
        audioEngineFactory: PipelineAudioEngineFactory(engines: [audio]),
        whisperEngine: PipelineScriptedWhisperEngine(texts: ["One", "Two", "Three", "Four"]),
        translationEngine: translation,
        overlayEngine: PipelineOverlayEngine(),
        settingsStore: PipelineSettingsStore()
    )

    await pipeline.start(mode: .translation, onError: { _ in })
    for index in 0..<4 {
        audio.yield(pipelineAudioChunk(timestamp: TimeInterval(index * 3)))
        try await pipelineEventually { await translation.callCount == index + 1 }
    }

    #expect(await translation.contextTexts == [
        [],
        ["One"],
        ["One", "Two"],
        ["Two", "Three"],
    ])
    await pipeline.stop()
}

@Test @MainActor
func translationWorkerSuppressesOnlyAdjacentDuplicateCandidates() async throws {
    let audio = PipelineAudioEngine()
    let translation = PipelineTranslationEngine()
    let pipeline = SubtitlePipeline(
        audioEngineFactory: PipelineAudioEngineFactory(engines: [audio]),
        whisperEngine: PipelineScriptedWhisperEngine(texts: [
            "Repeated subtitle",
            "Different subtitle",
            "Repeated subtitle",
        ]),
        translationEngine: translation,
        overlayEngine: PipelineOverlayEngine(),
        settingsStore: PipelineSettingsStore()
    )

    await pipeline.start(mode: .translation, onError: { _ in })
    for index in 0..<3 {
        audio.yield(pipelineAudioChunk(timestamp: TimeInterval(index * 3)))
        try await pipelineEventually { await translation.callCount == index + 1 }
    }

    #expect(await translation.originalTexts == [
        "Repeated subtitle",
        "Different subtitle",
        "Repeated subtitle",
    ])
    await pipeline.stop()
}

@Test @MainActor
func performanceDiagnosticsCountAdjacentTranslationDuplicates() async throws {
    let audio = PipelineAudioEngine()
    let translation = PipelineTranslationEngine()
    let recorder = PipelinePerformanceRecorder()
    let pipeline = SubtitlePipeline(
        audioEngineFactory: PipelineAudioEngineFactory(engines: [audio]),
        whisperEngine: PipelineScriptedWhisperEngine(texts: ["Same line", "Same line"]),
        translationEngine: translation,
        overlayEngine: PipelineOverlayEngine(),
        settingsStore: PipelineSettingsStore()
    )

    await pipeline.start(
        mode: .translation,
        onError: { _ in },
        onPerformanceDiagnostics: { await recorder.append($0) }
    )
    audio.yield(pipelineAudioChunk(timestamp: 0))
    try await pipelineEventually { await translation.callCount == 1 }
    audio.yield(pipelineAudioChunk(timestamp: 6))

    try await pipelineEventually(timeout: .seconds(2)) {
        await recorder.latest.duplicateTranslationCount == 1
    }
    #expect(await translation.callCount == 1)
    #expect(await recorder.latest.totalLatency.sampleCount == 1)
    await pipeline.stop()
}

@Test @MainActor
func translationWorkerDropsOldestPendingRequestsWhenQueueIsFull() async throws {
    let audio = PipelineAudioEngine()
    let texts = [
        "Alpha orchard", "Bravo mountain", "Charlie river", "Delta forest",
        "Echo harbor", "Foxtrot desert", "Golf meadow", "Hotel canyon",
        "India glacier", "Juliet island", "Kilo valley",
    ]
    let translation = BlockingPipelineTranslationEngine()
    let warnings = PipelineMessageRecorder()
    let transcripts = PipelineTranscriptRecorder()
    let performance = PipelinePerformanceRecorder()
    let pipeline = SubtitlePipeline(
        audioEngineFactory: PipelineAudioEngineFactory(engines: [audio]),
        whisperEngine: PipelineScriptedWhisperEngine(texts: texts),
        translationEngine: translation,
        overlayEngine: PipelineOverlayEngine(),
        settingsStore: PipelineSettingsStore()
    )

    await pipeline.start(
        mode: .translation,
        onError: { _ in },
        onWarning: { message in warnings.append(message) },
        onTranscript: { transcript in await transcripts.append(transcript) },
        onPerformanceDiagnostics: { await performance.append($0) }
    )
    for index in texts.indices {
        audio.yield(pipelineAudioChunk(timestamp: TimeInterval(index * 3)))
        try await pipelineEventually(timeout: .seconds(3)) {
            await transcripts.count >= index + 1
        }
    }

    #expect(await translation.callCount == 1)
    #expect(warnings.latest?.contains("Skipped 2") == true)
    await translation.releaseFirst()
    try await pipelineEventually { await translation.callCount == 9 }
    #expect(await translation.originalTexts == ["Alpha orchard"] + Array(texts[3...]))
    try await pipelineEventually(timeout: .seconds(2)) {
        await performance.latest.skippedTranslationCount == 2
    }
    await pipeline.stop()
}

@Test @MainActor
func permanentTranslationFailurePausesOnlyTranslationBranch() async throws {
    let audio = PipelineAudioEngine()
    let translation = FailingPipelineTranslationEngine(error: MLingoError.invalidAPIKey)
    let errors = PipelineMessageRecorder()
    let transcripts = PipelineTranscriptRecorder()
    let pipeline = SubtitlePipeline(
        audioEngineFactory: PipelineAudioEngineFactory(engines: [audio]),
        whisperEngine: PipelineScriptedWhisperEngine(texts: ["First", "Second"]),
        translationEngine: translation,
        overlayEngine: PipelineOverlayEngine(),
        settingsStore: PipelineSettingsStore()
    )

    await pipeline.start(
        mode: .translation,
        onError: { message in errors.append(message) },
        onTranscript: { transcript in await transcripts.append(transcript) }
    )
    audio.yield(pipelineAudioChunk(timestamp: 0))
    try await pipelineEventually { errors.count == 1 }
    audio.yield(pipelineAudioChunk(timestamp: 3))
    try await pipelineEventually { await transcripts.count == 2 }

    #expect(await translation.callCount == 1)
    #expect(audio.stopCount == 0)
    await pipeline.stop()
}

@Test @MainActor
func stoppedTranslationWorkerIgnoresLateResponse() async throws {
    let audio = PipelineAudioEngine()
    let translation = BlockingPipelineTranslationEngine()
    let overlay = PipelineOverlayEngine()
    let pipeline = SubtitlePipeline(
        audioEngineFactory: PipelineAudioEngineFactory(engines: [audio]),
        whisperEngine: PipelineWhisperEngine(text: "Late line"),
        translationEngine: translation,
        overlayEngine: overlay,
        settingsStore: PipelineSettingsStore()
    )

    await pipeline.start(mode: .translation, onError: { _ in })
    audio.yield(pipelineAudioChunk(timestamp: 0))
    try await pipelineEventually { await translation.callCount == 1 }
    await pipeline.stop()
    await translation.releaseFirst()
    try await Task.sleep(for: .milliseconds(30))

    #expect(overlay.updateCount == 0)
}

@Test @MainActor
func audioDiagnosticsSkipStaleSnapshotsWhenUIIsBusy() async throws {
    let audio = PipelineAudioEngine()
    let recorder = SlowAudioDiagnosticsRecorder()
    let pipeline = SubtitlePipeline(
        audioEngineFactory: PipelineAudioEngineFactory(engines: [audio]),
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

@Test @MainActor
func restartUsesFreshAudioEngineAndIgnoresPreviousSessionCallbacks() async throws {
    let firstAudio = PipelineAudioEngine()
    let secondAudio = PipelineAudioEngine()
    let factory = PipelineAudioEngineFactory(engines: [firstAudio, secondAudio])
    let transcripts = PipelineTranscriptRecorder()
    let diagnostics = PipelineAudioDiagnosticsRecorder()
    let pipeline = SubtitlePipeline(
        audioEngineFactory: factory,
        whisperEngine: PipelineWhisperEngine(text: "Restart transcript"),
        translationEngine: PipelineTranslationEngine(),
        overlayEngine: PipelineOverlayEngine(),
        settingsStore: PipelineSettingsStore()
    )

    await pipeline.start(
        mode: .transcriptionOnly,
        onError: { _ in },
        onAudioDiagnostics: { value in await diagnostics.append(value) },
        onTranscript: { value in await transcripts.append(value) }
    )
    firstAudio.yield(pipelineAudioChunk(timestamp: 1))
    try await pipelineEventually { await transcripts.count == 1 }
    await pipeline.stop()

    await pipeline.start(
        mode: .transcriptionOnly,
        onError: { _ in },
        onAudioDiagnostics: { value in await diagnostics.append(value) },
        onTranscript: { value in await transcripts.append(value) }
    )
    secondAudio.yieldDiagnostics(capturedChunkCount: 2)
    secondAudio.yield(pipelineAudioChunk(timestamp: 10))
    try await pipelineEventually {
        let transcriptCount = await transcripts.count
        let capturedChunkCount = await diagnostics.latestCapturedChunkCount
        return transcriptCount == 2 && capturedChunkCount == 2
    }

    firstAudio.yieldDiagnostics(capturedChunkCount: 99)
    firstAudio.yield(pipelineAudioChunk(timestamp: 99))
    try await Task.sleep(for: .milliseconds(50))

    #expect(factory.makeCount == 2)
    #expect(firstAudio.stopCount == 1)
    #expect(secondAudio.startCount == 1)
    #expect(await transcripts.count == 2)
    #expect(await diagnostics.latestCapturedChunkCount == 2)
    await pipeline.stop()
}

private final class PipelineAudioEngineFactory: AudioEngineFactoryProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var engines: [PipelineAudioEngine]
    private(set) var makeCount = 0
    private(set) var requestedBackends: [AudioCaptureBackend] = []

    init(engines: [PipelineAudioEngine]) {
        self.engines = engines
    }

    func makeAudioEngine(preferredBackend: AudioCaptureBackend) -> any AudioEngineProtocol {
        lock.withLock {
            makeCount += 1
            requestedBackends.append(preferredBackend)
            return engines.removeFirst()
        }
    }
}

private final class PipelineAudioEngine: AudioEngineProtocol, @unchecked Sendable {
    let chunks: AsyncStream<AudioChunk>
    let diagnostics: AsyncStream<AudioCaptureDiagnostics>
    private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    private let diagnosticsContinuation: AsyncStream<AudioCaptureDiagnostics>.Continuation
    private let startError: MLingoError?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(startError: MLingoError? = nil) {
        let (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let (diagnostics, diagnosticsContinuation) = AsyncStream.makeStream(
            of: AudioCaptureDiagnostics.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.chunks = chunks
        self.diagnostics = diagnostics
        self.chunkContinuation = chunkContinuation
        self.diagnosticsContinuation = diagnosticsContinuation
        self.startError = startError
    }

    var state: AudioCaptureState { get async { .running } }

    func start() async throws {
        startCount += 1
        if let startError { throw startError }
    }
    func stop() async { stopCount += 1 }

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

private actor PipelineAudioDiagnosticsRecorder {
    private var values: [AudioCaptureDiagnostics] = []

    var latestCapturedChunkCount: Int {
        values.last?.capturedChunkCount ?? 0
    }

    func append(_ diagnostics: AudioCaptureDiagnostics) {
        values.append(diagnostics)
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

private actor PipelineScriptedWhisperEngine: WhisperEngineProtocol {
    private var texts: [String]

    init(texts: [String]) {
        self.texts = texts
    }

    func loadModel(named modelName: String) async throws {}

    func transcribe(_ chunk: AudioChunk, language: String) async throws -> Transcript? {
        guard !texts.isEmpty else { return nil }
        return Transcript(text: texts.removeFirst(), timestamp: chunk.timestamp)
    }
}

private actor PipelineTranslationEngine: TranslationEngineProtocol {
    private(set) var callCount = 0
    private(set) var originalTexts: [String] = []
    private(set) var contextTexts: [[String]] = []

    func translate(_ request: TranslationRequest, settings: AppSettings) async throws -> SubtitleItem {
        callCount += 1
        let transcript = request.current
        originalTexts.append(transcript.text)
        contextTexts.append(request.context.map(\.text))
        return SubtitleItem(
            original: transcript.text,
            translated: "Bản dịch",
            start: transcript.timestamp,
            end: transcript.timestamp + 2
        )
    }
}

private actor BlockingPipelineTranslationEngine: TranslationEngineProtocol {
    private(set) var callCount = 0
    private(set) var originalTexts: [String] = []
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var shouldBlockFirst = true

    func translate(_ request: TranslationRequest, settings: AppSettings) async throws -> SubtitleItem {
        callCount += 1
        originalTexts.append(request.current.text)
        if shouldBlockFirst {
            shouldBlockFirst = false
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return SubtitleItem(
            original: request.current.text,
            translated: "Bản dịch",
            start: request.current.timestamp,
            end: request.current.timestamp + 2
        )
    }

    func releaseFirst() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor FailingPipelineTranslationEngine: TranslationEngineProtocol {
    let error: any Error
    private(set) var callCount = 0

    init(error: any Error) {
        self.error = error
    }

    func translate(_ request: TranslationRequest, settings: AppSettings) async throws -> SubtitleItem {
        callCount += 1
        throw error
    }
}

@MainActor
private final class PipelineOverlayEngine: OverlayEngineProtocol {
    let presentationState = OverlayPresentationState()
    private(set) var showCount = 0
    private(set) var updateCount = 0
    private(set) var hideCount = 0
    private(set) var commandCount = 0
    private(set) var lastSubtitle: SubtitleItem?
    private(set) var lastShownSettings: AppSettings?

    func show(settings: AppSettings) {
        showCount += 1
        lastShownSettings = settings
        presentationState.isVisible = true
    }

    func update(with subtitle: SubtitleItem, settings: AppSettings) {
        updateCount += 1
        lastSubtitle = subtitle
    }

    func hide() {
        hideCount += 1
        presentationState.isVisible = false
        presentationState.isEditing = false
    }

    func setVisible(_ isVisible: Bool) {
        commandCount += 1
        presentationState.isVisible = isVisible
    }

    func beginRepositioning() {
        commandCount += 1
        presentationState.isVisible = true
        presentationState.isEditing = true
    }

    func endRepositioning() {
        commandCount += 1
        presentationState.isEditing = false
    }

    func resetPosition() { commandCount += 1 }

    func selectDisplay(_ selection: OverlayDisplaySelection) {
        commandCount += 1
        presentationState.selectedDisplay = selection
    }
}

private actor PipelineSettingsStore: SettingsStoreProtocol {
    private var settings: AppSettings

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

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

private final class PipelineMessageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var count: Int { lock.withLock { values.count } }
    var latest: String? { lock.withLock { values.last } }

    func append(_ message: String) {
        lock.withLock { values.append(message) }
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

private actor PipelinePerformanceRecorder {
    private var values: [PipelinePerformanceDiagnostics] = []
    var latest: PipelinePerformanceDiagnostics {
        values.last ?? PipelinePerformanceDiagnostics()
    }

    func append(_ diagnostics: PipelinePerformanceDiagnostics) {
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
