import MLingoCore
import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: MLingoViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("API key", text: $viewModel.apiKey)
                    .textContentType(.password)
                    .accessibilityLabel("OpenAI API key")

                TextField("Model", text: $viewModel.settings.openAIModel)
                    .accessibilityLabel("OpenAI translation model")
            }

            Section("Whisper") {
                TextField("Model", text: $viewModel.settings.whisperModel)
                    .accessibilityLabel("Whisper model")
            }

            Section("Subtitles") {
                Slider(value: $viewModel.settings.subtitleFontSize, in: 18...64, step: 1) {
                    Text("Font size")
                } minimumValueLabel: {
                    Text("18")
                } maximumValueLabel: {
                    Text("64")
                }

                Slider(value: $viewModel.settings.subtitleBackgroundOpacity, in: 0.2...0.9, step: 0.01) {
                    Text("Background opacity")
                } minimumValueLabel: {
                    Text("20%")
                } maximumValueLabel: {
                    Text("90%")
                }

                Toggle("Show bilingual subtitles", isOn: $viewModel.settings.showBilingualSubtitles)
            }

            Section("Languages") {
                TextField("Source language", text: $viewModel.settings.sourceLanguage)
                TextField("Target language", text: $viewModel.settings.targetLanguage)
            }

            Section("Appearance") {
                Picker("Theme", selection: $viewModel.settings.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue.capitalized).tag(theme)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    Task {
                        await viewModel.save()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await viewModel.load()
        }
    }
}
