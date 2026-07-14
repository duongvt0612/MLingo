import MLingoCore
import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: MLingoViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draftSettings: AppSettings

    init(viewModel: MLingoViewModel) {
        self.viewModel = viewModel
        _draftSettings = State(initialValue: viewModel.settings)
    }

    var body: some View {
        Form {
            Section {
                Picker("Capture audio using", selection: $draftSettings.audioCaptureBackend) {
                    ForEach(AudioCaptureBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityLabel("Audio capture backend")
            } header: {
                Text("Audio capture")
            } footer: {
                Text(audioCaptureHelpText)
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI") {
                SecureField("API key", text: $viewModel.apiKey)
                    .textContentType(.password)
                    .accessibilityLabel("OpenAI API key")

                TextField("Model", text: $draftSettings.openAIModel)
                    .accessibilityLabel("OpenAI translation model")
            }

            Section("Whisper") {
                TextField("Model", text: $draftSettings.whisperModel)
                    .accessibilityLabel("Whisper model")
            }

            Section("Subtitles") {
                Slider(value: $draftSettings.subtitleFontSize, in: 18...64, step: 1) {
                    Text("Font size")
                } minimumValueLabel: {
                    Text("18")
                } maximumValueLabel: {
                    Text("64")
                }

                Slider(value: $draftSettings.subtitleBackgroundOpacity, in: 0.2...0.9, step: 0.01) {
                    Text("Background opacity")
                } minimumValueLabel: {
                    Text("20%")
                } maximumValueLabel: {
                    Text("90%")
                }

                Toggle("Show bilingual subtitles", isOn: $draftSettings.showBilingualSubtitles)
            }

            Section("Languages") {
                TextField("Source language", text: $draftSettings.sourceLanguage)
                TextField("Target language", text: $draftSettings.targetLanguage)
            }

            Section("Appearance") {
                Picker("Theme", selection: $draftSettings.theme) {
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
                        if await viewModel.save(draftSettings) {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var audioCaptureHelpText: String {
        switch draftSettings.audioCaptureBackend {
        case .coreAudioTap:
            if #available(macOS 14.2, *) {
                "Captures system audio directly and requires System Audio Recording permission."
            } else {
                "Requires macOS 14.2 or newer. On this macOS version, MLingo uses Screen Recording instead."
            }
        case .screenCaptureKit:
            "Captures system audio through ScreenCaptureKit and requires Screen Recording permission."
        }
    }
}
