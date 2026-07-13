import MLingoCore
import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: MLingoViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                mainContent
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.load()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MLingo")
                    .font(.system(size: 26, weight: .semibold))
                Text("Live subtitles for macOS audio")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityLabel("Open settings")

            Button {
                viewModel.isTestingSound ? viewModel.stopSoundTest() : viewModel.startSoundTest()
            } label: {
                Label(viewModel.isTestingSound ? "Stop Test" : "Test Sound", systemImage: viewModel.isTestingSound ? "stop.fill" : "waveform.path.ecg")
                    .frame(minWidth: 104)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isActive && !viewModel.isTestingSound)
            .accessibilityLabel(viewModel.isTestingSound ? "Stop sound test" : "Test system audio capture")

            Button {
                viewModel.isRunning ? viewModel.stop() : viewModel.start()
            } label: {
                Label(viewModel.isRunning ? "Stop" : "Start Translate", systemImage: viewModel.isRunning ? "stop.fill" : "play.fill")
                    .frame(minWidth: 128)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(viewModel.isActive && !viewModel.isRunning)
            .accessibilityLabel(viewModel.isRunning ? "Stop live translation" : "Start live translation")
        }
        .padding(.top, 14)
        .padding(.leading, 84)
        .padding(.trailing, 24)
        .padding(.bottom, 16)
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 18) {
            statusPanel
            settingsSummary
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                Label(viewModel.status, systemImage: statusIconName)
                    .font(.title3.weight(.semibold))
                    .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating, value: viewModel.isActive)

                Spacer()

                Text(modeLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }

            if let lastError = viewModel.lastError {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Error: \(lastError)")
            } else {
                Text(privacyDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            readinessGrid

            audioDiagnosticsPanel

            Divider()

            transcriptionDiagnosticsPanel
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var readinessGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 10) {
            GridRow {
                progressRow("System audio capture", isReady: isSystemAudioCaptureReady)
                whisperModelStatusRow
            }
            GridRow {
                progressRow("OpenAI API key", isReady: !viewModel.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                progressRow("Subtitle overlay", isReady: true)
            }
        }
    }

    @ViewBuilder
    private var whisperModelStatusRow: some View {
        Group {
            switch viewModel.whisperDiagnostics.modelState {
            case .loading:
                Label {
                    Text("Whisper: Loading")
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
            case .ready:
                Label("Whisper: Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .idle:
                Label("Whisper: Idle", systemImage: "circle")
                    .foregroundStyle(.secondary)
            case .failed:
                Label("Whisper: Failed", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var audioDiagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Audio diagnostics", systemImage: "waveform.path.ecg")
                    .font(.headline)
                    .accessibilityLabel("Audio diagnostics")
                Spacer()
                Text(viewModel.audioDiagnostics.state.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                levelBar("RMS", value: Double(viewModel.audioDiagnostics.rms), scale: 0.15)
                levelBar("Peak", value: Double(viewModel.audioDiagnostics.peak), scale: 0.30)
            }

            Divider()

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 120), alignment: .leading)
                ],
                alignment: .leading,
                spacing: 12
            ) {
                diagnosticMetric("Sample rate", "\(Int(viewModel.audioDiagnostics.sampleRate)) Hz")
                diagnosticMetric("Channels", "\(viewModel.audioDiagnostics.channelCount)")
                diagnosticMetric("Duration", "\(Int(viewModel.audioDiagnostics.lastChunkDuration * 1000)) ms")
                diagnosticMetric("Captured", "\(viewModel.audioDiagnostics.capturedChunkCount)")
                diagnosticMetric("Dropped", "\(viewModel.audioDiagnostics.droppedChunkCount)")
                diagnosticMetric("Empty", "\(viewModel.audioDiagnostics.emptyChunkCount)")
                diagnosticMetric("Speech-like", "\(viewModel.audioDiagnostics.speechLikeChunkCount)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcriptionDiagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Label("Transcription diagnostics", systemImage: "captions.bubble")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.isTestingTranscription
                        ? viewModel.stopTranscriptionTest()
                        : viewModel.startTranscriptionTest()
                } label: {
                    Label(
                        viewModel.isTestingTranscription ? "Stop Test" : "Test Transcription",
                        systemImage: viewModel.isTestingTranscription ? "stop.fill" : "text.bubble"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isActive && !viewModel.isTestingTranscription)
                .accessibilityLabel(
                    viewModel.isTestingTranscription
                        ? "Stop transcription test"
                        : "Start transcription test"
                )
            }

            if viewModel.whisperDiagnostics.modelState == .loading {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading or loading model…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)],
                alignment: .leading,
                spacing: 12
            ) {
                diagnosticMetric("Model state", viewModel.whisperDiagnostics.modelState.displayName)
                diagnosticMetric("Window", "\(Int(viewModel.whisperDiagnostics.windowDuration * 1000)) ms")
                diagnosticMetric("Latency", "\(Int(viewModel.whisperDiagnostics.inferenceLatency * 1000)) ms")
                diagnosticMetric("Processed", "\(viewModel.whisperDiagnostics.processedWindowCount)")
                diagnosticMetric("Duplicates", "\(viewModel.whisperDiagnostics.suppressedDuplicateCount)")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model ID")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(viewModel.whisperDiagnostics.modelID.isEmpty ? viewModel.settings.whisperModel : viewModel.whisperDiagnostics.modelID)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Last transcript")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(viewModel.whisperDiagnostics.lastTranscript.isEmpty ? "No transcript yet" : viewModel.whisperDiagnostics.lastTranscript)
                    .font(.callout)
                    .foregroundStyle(viewModel.whisperDiagnostics.lastTranscript.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsSummary: some View {
        VStack(alignment: .leading, spacing: 20) {
            summarySection("Translation") {
                summaryRow("Source", viewModel.settings.sourceLanguage)
                summaryRow("Target", viewModel.settings.targetLanguage)
                summaryRow("OpenAI model", viewModel.settings.openAIModel)
            }

            summarySection("Subtitles") {
                summaryRow("Font size", "\(Int(viewModel.settings.subtitleFontSize)) pt")
                summaryRow("Background", "\(Int(viewModel.settings.subtitleBackgroundOpacity * 100))%")
                summaryRow("Bilingual", viewModel.settings.showBilingualSubtitles ? "On" : "Off")
            }
        }
        .padding(20)
        .frame(width: 320, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func progressRow(_ text: String, isReady: Bool) -> some View {
        Label(text, systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(isReady ? .green : .orange)
            .font(.callout)
    }

    private var isSystemAudioCaptureReady: Bool {
        viewModel.audioDiagnostics.state == .running
    }

    private var statusIconName: String {
        if viewModel.isActive {
            return "waveform"
        }
        if viewModel.lastError != nil {
            return "exclamationmark.triangle"
        }
        return "checkmark.circle"
    }

    private var modeLabel: String {
        switch viewModel.activeMode {
        case .idle:
            "Idle"
        case .soundTest:
            "Sound test"
        case .transcriptionTest:
            "Transcription test"
        case .translation:
            "Translation"
        }
    }

    private var privacyDescription: String {
        switch viewModel.activeMode {
        case .soundTest:
            "Testing audio capture only. Whisper and OpenAI are not used in this mode."
        case .transcriptionTest:
            "Audio and transcription stay on this Mac. OpenAI and the subtitle overlay are not used."
        default:
            "Audio stays local. Only recognized text is sent to OpenAI for translation."
        }
    }

    private func levelBar(_ title: String, value: Double, scale: Double) -> some View {
        let normalized = min(max(value / scale, 0), 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value.formatted(.number.precision(.fractionLength(4))))
                    .font(.caption.monospacedDigit())
                    .textSelection(.enabled)
            }
            ProgressView(value: normalized)
                .accessibilityLabel("\(title) audio level")
        }
    }

    private func diagnosticMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .textSelection(.enabled)
        }
    }

    private func summarySection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(spacing: 0) {
                content()
            }
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .padding(.vertical, 7)
    }
}

private extension AudioCaptureState {
    var displayName: String {
        switch self {
        case .idle:
            "Idle"
        case .requestingPermission:
            "Requesting permission"
        case .running:
            "Running"
        case .stopped:
            "Stopped"
        case .failed:
            "Failed"
        }
    }
}

private extension WhisperModelState {
    var displayName: String {
        switch self {
        case .idle:
            "Idle"
        case .loading:
            "Loading"
        case .ready:
            "Ready"
        case .failed:
            "Failed"
        }
    }
}
