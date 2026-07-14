import MLingoCore
import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: MLingoViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draftSettings: AppSettings
    @State private var draftAPIKey: String
    @State private var showsOpenAIValidation = false
    @State private var translationTestTask: Task<Void, Never>?

    init(viewModel: MLingoViewModel) {
        self.viewModel = viewModel
        _draftSettings = State(initialValue: viewModel.settings)
        _draftAPIKey = State(initialValue: viewModel.apiKey)
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
                SecureField("API key", text: $draftAPIKey)
                    .textContentType(.password)
                    .accessibilityLabel("OpenAI API key")
                    .disabled(viewModel.isTranslationTestRunning)
                validationMessage(openAIValidation.apiKeyError)

                TextField("Model", text: $draftSettings.openAIModel)
                    .accessibilityLabel("OpenAI translation model")
                    .disabled(viewModel.isTranslationTestRunning)
                validationMessage(openAIValidation.modelError)

                Text("Recommended default: gpt-5.4-mini")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    showsOpenAIValidation = true
                    translationTestTask?.cancel()
                    translationTestTask = Task {
                        await viewModel.testTranslation(
                            apiKey: draftAPIKey,
                            settings: draftSettings
                        )
                    }
                } label: {
                    Label(
                        viewModel.isTranslationTestRunning ? "Testing…" : "Test translation",
                        systemImage: "checkmark.bubble"
                    )
                }
                .disabled(viewModel.isActive || viewModel.isTranslationTestRunning)
                .accessibilityHint("Translates a fixed Docker and PostgreSQL sentence without saving these settings")

                if viewModel.isActive {
                    Text("Stop the active session before testing. Saved changes apply to the next session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                translationTestFeedback
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
                    .disabled(viewModel.isTranslationTestRunning)
                validationMessage(openAIValidation.sourceLanguageError)
                TextField("Target language", text: $draftSettings.targetLanguage)
                    .disabled(viewModel.isTranslationTestRunning)
                validationMessage(openAIValidation.targetLanguageError)
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
                    showsOpenAIValidation = true
                    guard openAIValidation.hasValidTranslationSettings else { return }
                    Task {
                        if await viewModel.save(draftSettings, apiKey: draftAPIKey) {
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
        .onAppear { viewModel.resetTranslationTest() }
        .onChange(of: draftAPIKey) { _, _ in viewModel.resetTranslationTest() }
        .onChange(of: draftSettings.openAIModel) { _, _ in viewModel.resetTranslationTest() }
        .onChange(of: draftSettings.sourceLanguage) { _, _ in viewModel.resetTranslationTest() }
        .onChange(of: draftSettings.targetLanguage) { _, _ in viewModel.resetTranslationTest() }
        .onDisappear {
            translationTestTask?.cancel()
            translationTestTask = nil
        }
    }

    private var openAIValidation: OpenAISettingsValidation {
        OpenAISettingsValidation(apiKey: draftAPIKey, settings: draftSettings)
    }

    @ViewBuilder
    private func validationMessage(_ message: String?) -> some View {
        if showsOpenAIValidation, let message {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel("Validation error: \(message)")
        }
    }

    @ViewBuilder
    private var translationTestFeedback: some View {
        switch viewModel.translationTestState {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Testing OpenAI translation…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Testing OpenAI translation")
        case .success(let result):
            VStack(alignment: .leading, spacing: 8) {
                Label("Translation test passed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.semibold))
                Text(result.original)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(result.translated)
                    .textSelection(.enabled)
                Text("\(result.model) • \(Int((result.latency * 1_000).rounded())) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Translation test passed using \(result.model) in \(Int((result.latency * 1_000).rounded())) milliseconds. \(result.translated)"
            )
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .accessibilityLabel("Translation test failed: \(message)")
        }
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
