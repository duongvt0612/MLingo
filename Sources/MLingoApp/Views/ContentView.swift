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
            mainContent
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
                    .font(.system(size: 28, weight: .semibold))
                Text("Live English to Vietnamese subtitles for macOS audio")
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
                viewModel.isRunning ? viewModel.stop() : viewModel.start()
            } label: {
                Label(viewModel.isRunning ? "Stop" : "Start", systemImage: viewModel.isRunning ? "stop.fill" : "play.fill")
                    .frame(minWidth: 92)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityLabel(viewModel.isRunning ? "Stop live translation" : "Start live translation")
        }
        .padding(24)
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 18) {
            statusPanel
            settingsSummary
        }
        .padding(24)
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(viewModel.status, systemImage: viewModel.isRunning ? "waveform" : "checkmark.circle")
                .font(.title3.weight(.semibold))
                .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating, value: viewModel.isRunning)

            if let lastError = viewModel.lastError {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Error: \(lastError)")
            } else {
                Text("Audio stays local. Only recognized text is sent to OpenAI for translation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                progressRow("System audio capture", isReady: true)
                progressRow("Local Whisper boundary", isReady: true)
                progressRow("OpenAI API key", isReady: !viewModel.apiKey.isEmpty)
                progressRow("Floating subtitle overlay", isReady: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var settingsSummary: some View {
        Form {
            Section("Translation") {
                LabeledContent("Source", value: viewModel.settings.sourceLanguage)
                LabeledContent("Target", value: viewModel.settings.targetLanguage)
                LabeledContent("OpenAI model", value: viewModel.settings.openAIModel)
            }

            Section("Subtitles") {
                LabeledContent("Font size", value: "\(Int(viewModel.settings.subtitleFontSize)) pt")
                LabeledContent("Background", value: "\(Int(viewModel.settings.subtitleBackgroundOpacity * 100))%")
                LabeledContent("Bilingual", value: viewModel.settings.showBilingualSubtitles ? "On" : "Off")
            }
        }
        .formStyle(.grouped)
        .frame(width: 300)
    }

    private func progressRow(_ text: String, isReady: Bool) -> some View {
        Label(text, systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(isReady ? .green : .orange)
            .font(.callout)
    }
}
