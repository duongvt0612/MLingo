@preconcurrency import AVFoundation
import AppKit
import Foundation
import Testing
@testable import MLingoCore

@Suite(.serialized)
struct PerformanceBenchmarkTests {
    @Test
    func whisperTinyBaseSmallBenchmark() async throws {
        guard performanceBenchmarksEnabled else {
            print("Skipping performance benchmark: set MLINGO_RUN_PERFORMANCE_BENCHMARKS=1")
            return
        }
        let chunk = try performanceAudioFixture()
        let candidates = [
            "mlx-community/whisper-tiny-asr-fp16",
            "mlx-community/whisper-base-asr-fp16",
            "mlx-community/whisper-small-asr-fp16",
        ]

        for modelID in candidates {
            let engine = MLXWhisperEngine()
            do {
                try await engine.loadModel(named: modelID)
            } catch {
                print("Skipping MLX benchmark model=\(modelID): \(error)")
                continue
            }

            _ = try await engine.transcribe(chunk, language: "English")
            var latencies: [TimeInterval] = []
            for _ in 0..<10 {
                let startedAt = ContinuousClock.now
                let transcript = try await engine.transcribe(chunk, language: "English")
                latencies.append(startedAt.duration(to: .now).timeInterval)
                let text = try #require(transcript?.text.lowercased())
                #expect(text.contains("ask not what your country can do for you"))
            }

            let p50 = try #require(nearestRank(0.50, samples: latencies))
            let p95 = try #require(nearestRank(0.95, samples: latencies))
            print(
                "Whisper benchmark model=\(modelID) p50=\(p50)s p95=\(p95)s "
                    + "realtime_factor=\(p95 / chunk.duration)"
            )
        }
    }

    @MainActor
    @Test
    func liveEndToEndPerformanceBenchmark() async throws {
        guard performanceBenchmarksEnabled else {
            print("Skipping live end-to-end benchmark: performance benchmarks are disabled")
            return
        }
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            print("Skipping live end-to-end benchmark: OPENAI_API_KEY is not set")
            return
        }
        guard !NSScreen.screens.isEmpty else {
            print("Skipping live end-to-end benchmark: WindowServer is unavailable")
            return
        }

        let chunk = try performanceAudioFixture()
        let whisper = MLXWhisperEngine()
        do {
            try await whisper.loadModel(named: "mlx-community/whisper-base-mlx")
        } catch {
            print("Skipping live end-to-end benchmark because MLX could not load: \(error)")
            return
        }
        _ = try await whisper.transcribe(chunk, language: "English")

        let translation = OpenAITranslationEngine(
            apiKeyStore: PerformanceAPIKeyStore(apiKey: apiKey)
        )
        let overlay = FloatingSubtitleWindowController()
        let settings = AppSettings(sourceLanguage: "English", targetLanguage: "Vietnamese")
        var totalLatencies: [TimeInterval] = []
        var renderLatencies: [TimeInterval] = []
        defer { overlay.hide() }

        for _ in 0..<10 {
            overlay.show(settings: settings)
            let speechEndedAt = ContinuousClock.now
            let transcript = try #require(
                try await whisper.transcribe(chunk, language: settings.sourceLanguage)
            )
            let subtitle = try await translation.translate(
                TranslationRequest(current: transcript),
                settings: settings
            )
            let renderStartedAt = ContinuousClock.now
            overlay.update(with: subtitle, settings: settings)
            let renderEndedAt = ContinuousClock.now
            overlay.hide()

            totalLatencies.append(speechEndedAt.duration(to: renderEndedAt).timeInterval)
            renderLatencies.append(renderStartedAt.duration(to: renderEndedAt).timeInterval)
        }

        let totalP95 = try #require(nearestRank(0.95, samples: totalLatencies))
        let renderP95 = try #require(nearestRank(0.95, samples: renderLatencies))
        print("End-to-end benchmark p95=\(totalP95)s overlay_p95=\(renderP95)s")
        #expect(totalP95 < 2)
        #expect(renderP95 < 0.1)
    }

    @MainActor
    @Test
    func oneHourMemoryStabilityBenchmark() async throws {
        guard performanceBenchmarksEnabled else {
            print("Skipping stability benchmark: performance benchmarks are disabled")
            return
        }

        let configuredDuration = ProcessInfo.processInfo.environment[
            "MLINGO_PERFORMANCE_DURATION_SECONDS"
        ].flatMap(TimeInterval.init) ?? 3_600
        let duration = max(1, configuredDuration)
        let warmupDuration = duration >= 600 ? 300 : duration * 0.1
        let fixture = try performanceAudioFixture()
        let sampleCount = min(fixture.samples.count, 48_000)
        let chunk = AudioChunk(
            samples: Array(fixture.samples.prefix(sampleCount)),
            sampleRate: 16_000,
            channelCount: 1,
            timestamp: 0,
            duration: Double(sampleCount) / 16_000
        )
        let audio = PerformanceLoopAudioEngine(chunk: chunk)
        let recorder = PerformanceDiagnosticsRecorder()
        let runtime = SessionOrchestrator(
            audioEngineFactory: PerformanceAudioEngineFactory(engine: audio),
            whisperEngine: MLXWhisperEngine(),
            translationEngine: PerformanceTranslationEngine(),
            overlayEngine: PerformanceOverlayEngine(),
            settingsStore: PerformanceSettingsStore()
        )
        let started = await runtime.start(
            kind: .transcription,
            onError: { error in print("Stability runtime error: \(error.localizedDescription)") },
            onPerformanceDiagnostics: { await recorder.append($0) }
        )
        guard started else {
            print("Skipping stability benchmark because the MLX runtime could not start")
            return
        }
        do {
            try await Task.sleep(for: .seconds(duration))
        } catch {
            await runtime.stop(reason: .cancelled)
            throw error
        }
        await runtime.stop(reason: .cancelled)

        let recordedDiagnostics = await recorder.values.filter {
            $0.residentMemoryBytes != nil && $0.sessionDuration > 0
        }
        let firstDuration = recordedDiagnostics.first?.sessionDuration ?? 0
        let postWarmup = recordedDiagnostics.filter {
            $0.sessionDuration - firstDuration >= warmupDuration
        }
        let memorySamples = postWarmup.compactMap { diagnostics in
            diagnostics.residentMemoryBytes.map {
                (time: diagnostics.sessionDuration - firstDuration - warmupDuration, bytes: $0)
            }
        }
        let latestCPU = postWarmup.last?.cpuUsagePercent

        guard memorySamples.count >= 2 else {
            print("Stability smoke run completed without enough post-warm-up RSS samples")
            return
        }
        let netGrowth = Int64(memorySamples.last!.bytes) - Int64(memorySamples.first!.bytes)
        let slope = leastSquaresSlope(memorySamples)
        let cpuDescription = latestCPU.map { String($0) } ?? "unavailable"
        let stabilityReport = "Stability benchmark rss_net=\(netGrowth)B "
            + "rss_slope=\(slope * 60)B/min cpu=\(cpuDescription)%"
        print(stabilityReport)
        #expect(netGrowth <= 100 * 1_024 * 1_024)
        #expect(slope <= Double(1_024 * 1_024) / 60)
    }

    @Test
    func repeatedWhisperStartStopBenchmark() async throws {
        guard performanceBenchmarksEnabled else {
            print("Skipping lifecycle benchmark: performance benchmarks are disabled")
            return
        }
        let chunk = try performanceAudioFixture()
        let coordinator = WhisperTranscriptionCoordinator(engine: MLXWhisperEngine())
        let sampler = DarwinProcessMetricsSampler()
        await sampler.reset()
        let rssBefore = await sampler.sample()?.residentMemoryBytes

        for _ in 0..<10 {
            do {
                try await coordinator.start(
                    modelID: "mlx-community/whisper-base-mlx",
                    language: "English",
                    onTranscript: { _ in }
                )
            } catch {
                print("Skipping lifecycle benchmark because MLX could not load: \(error)")
                return
            }
            await coordinator.ingest(chunk)
            try await Task.sleep(for: .milliseconds(10))
            await coordinator.stop()
        }
        let rssAfter = await sampler.sample()?.residentMemoryBytes
        if let rssBefore, let rssAfter {
            print("Lifecycle benchmark rss_net=\(Int64(rssAfter) - Int64(rssBefore))B")
        }
    }
}

private var performanceBenchmarksEnabled: Bool {
    ProcessInfo.processInfo.environment["MLINGO_RUN_PERFORMANCE_BENCHMARKS"] == "1"
}

private func nearestRank(_ percentile: Double, samples: [TimeInterval]) -> TimeInterval? {
    guard !samples.isEmpty else { return nil }
    let sorted = samples.sorted()
    let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
    return sorted[min(rank - 1, sorted.count - 1)]
}

private func leastSquaresSlope(_ samples: [(time: TimeInterval, bytes: UInt64)]) -> Double {
    let count = Double(samples.count)
    let sumX = samples.reduce(0) { $0 + $1.time }
    let sumY = samples.reduce(0) { $0 + Double($1.bytes) }
    let sumXY = samples.reduce(0) { $0 + $1.time * Double($1.bytes) }
    let sumXX = samples.reduce(0) { $0 + $1.time * $1.time }
    let denominator = count * sumXX - sumX * sumX
    guard denominator > 0 else { return 0 }
    return (count * sumXY - sumX * sumY) / denominator
}

private func performanceAudioFixture() throws -> AudioChunk {
    let fixtureURL = try #require(
        Bundle.module.url(
            forResource: "jfk",
            withExtension: "flac",
            subdirectory: "Fixtures"
        )
    )
    let file = try AVAudioFile(forReading: fixtureURL)
    let frameCount = AVAudioFrameCount(file.length)
    let sourceBuffer = try #require(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
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
    let converter = try #require(
        AVAudioConverter(from: file.processingFormat, to: targetFormat)
    )
    let capacity = AVAudioFrameCount(
        ceil(Double(sourceBuffer.frameLength) * 16_000 / file.processingFormat.sampleRate)
    ) + 1
    let outputBuffer = try #require(
        AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
    )
    let provider = PerformanceAudioInputProvider(buffer: sourceBuffer)
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
        provider.next(status: inputStatus)
    }
    if status == .error {
        throw conversionError ?? MLingoError.captureFailed("Could not convert JFK fixture")
    }
    let channelData = try #require(outputBuffer.floatChannelData)
    let samples = Array(
        UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength))
    )
    return AudioChunk(
        samples: samples,
        sampleRate: 16_000,
        channelCount: 1,
        timestamp: 0,
        duration: Double(samples.count) / 16_000
    )
}

private final class PerformanceAudioInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var hasProvidedBuffer = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
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

private final class PerformanceAPIKeyStore: APIKeyStoreProtocol, @unchecked Sendable {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func loadAPIKey() throws -> String? { apiKey }
    func saveAPIKey(_ apiKey: String) throws {}
    func deleteAPIKey() throws {}
}

private final class PerformanceLoopAudioEngine: AudioEngineProtocol, @unchecked Sendable {
    let chunks: AsyncStream<AudioChunk>
    let diagnostics: AsyncStream<AudioCaptureDiagnostics>

    private let lock = NSLock()
    private let chunk: AudioChunk
    private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    private let diagnosticsContinuation: AsyncStream<AudioCaptureDiagnostics>.Continuation
    private var currentState: AudioCaptureState = .idle
    private var task: Task<Void, Never>?

    init(chunk: AudioChunk) {
        self.chunk = chunk
        let chunkStream = AsyncStream.makeStream(of: AudioChunk.self)
        chunks = chunkStream.stream
        chunkContinuation = chunkStream.continuation
        let diagnosticsStream = AsyncStream.makeStream(of: AudioCaptureDiagnostics.self)
        diagnostics = diagnosticsStream.stream
        diagnosticsContinuation = diagnosticsStream.continuation
    }

    var state: AudioCaptureState {
        get async { lock.withLock { currentState } }
    }

    func start() async throws {
        lock.withLock { currentState = .running }
        diagnosticsContinuation.yield(AudioCaptureDiagnostics(state: .running))
        let chunk = self.chunk
        let continuation = chunkContinuation
        task = Task {
            var timestamp: TimeInterval = 0
            while !Task.isCancelled {
                continuation.yield(
                    AudioChunk(
                        samples: chunk.samples,
                        sampleRate: chunk.sampleRate,
                        channelCount: chunk.channelCount,
                        timestamp: timestamp,
                        duration: chunk.duration,
                        isSpeechLike: true
                    )
                )
                timestamp += chunk.duration
                do {
                    try await Task.sleep(for: .seconds(chunk.duration))
                } catch {
                    return
                }
            }
        }
    }

    func stop() async {
        task?.cancel()
        await task?.value
        task = nil
        lock.withLock { currentState = .stopped }
    }
}

private struct PerformanceAudioEngineFactory: AudioEngineFactoryProtocol {
    let engine: PerformanceLoopAudioEngine

    func makeAudioEngine(preferredBackend: AudioCaptureBackend) -> any AudioEngineProtocol {
        engine
    }
}

private actor PerformanceSettingsStore: SettingsStoreProtocol {
    private var settings = AppSettings(whisperModel: "mlx-community/whisper-base-mlx")
    func load() async throws -> AppSettings { settings }
    func save(_ settings: AppSettings) async throws { self.settings = settings }
}

private actor PerformanceTranslationEngine: TranslationEngineProtocol {
    func translate(_ request: TranslationRequest, settings: AppSettings) async throws -> SubtitleItem {
        SubtitleItem(
            original: request.current.text,
            translated: request.current.text,
            start: request.current.timestamp,
            end: request.current.timestamp + 1
        )
    }
}

@MainActor
private final class PerformanceOverlayEngine: OverlayEngineProtocol {
    let presentationState = OverlayPresentationState()
    func show(settings: AppSettings) {}
    func update(with subtitle: SubtitleItem, settings: AppSettings) {}
    func hide() {}
    func setVisible(_ isVisible: Bool) {}
    func beginRepositioning() {}
    func endRepositioning() {}
    func resetPosition() {}
    func selectDisplay(_ selection: OverlayDisplaySelection) {}
}

private actor PerformanceDiagnosticsRecorder {
    private(set) var values: [PipelinePerformanceDiagnostics] = []
    func append(_ diagnostics: PipelinePerformanceDiagnostics) { values.append(diagnostics) }
}
