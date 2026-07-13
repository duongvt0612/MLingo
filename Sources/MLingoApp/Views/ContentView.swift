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
            .disabled(viewModel.isRunning)
            .accessibilityLabel(viewModel.isTestingSound ? "Stop sound test" : "Test system audio capture")

            Button {
                viewModel.isRunning ? viewModel.stop() : viewModel.start()
            } label: {
                Label(viewModel.isRunning ? "Stop" : "Start Translate", systemImage: viewModel.isRunning ? "stop.fill" : "play.fill")
                    .frame(minWidth: 128)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(viewModel.isTestingSound)
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
                    .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating, value: viewModel.isRunning || viewModel.isTestingSound)

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
                Text(viewModel.isTestingSound ? "Testing audio capture only. Whisper and OpenAI are not used in this mode." : "Audio stays local. Only recognized text is sent to OpenAI for translation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            readinessGrid

            audioDiagnosticsPanel
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var readinessGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 10) {
            GridRow {
                progressRow("System audio capture", isReady: isSystemAudioCaptureReady)
                progressRow("Whisper boundary", isReady: true)
            }
            GridRow {
                progressRow("OpenAI API key", isReady: !viewModel.apiKey.isEmpty)
                progressRow("Subtitle overlay", isReady: true)
            }
        }
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
        if viewModel.isRunning || viewModel.isTestingSound {
            return "waveform"
        }
        if viewModel.lastError != nil {
            return "exclamationmark.triangle"
        }
        return "checkmark.circle"
    }

    private var modeLabel: String {
        if viewModel.isTestingSound {
            return "Sound test"
        }
        if viewModel.isRunning {
            return "Translation"
        }
        return "Idle"
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
