import MLingoCore
import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: MLingoViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SettingsDraft()
    @State private var isDraftLoaded = false
    @State private var showsOpenAIValidation = false
    @State private var translationTestTask: Task<Void, Never>?

    init(viewModel: MLingoViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        Form {
            Section {
                Picker("Capture audio using", selection: $draft.settings.audioCaptureBackend) {
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
                SecureField("API key", text: $draft.apiKey)
                    .textContentType(.password)
                    .accessibilityLabel("OpenAI API key")
                    .disabled(viewModel.isTranslationTestRunning)
                validationMessage(openAIValidation.apiKeyError)

                TextField("Model", text: $draft.settings.openAIModel)
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
                            apiKey: draft.apiKey,
                            settings: draft.settings
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
                TextField("Model", text: $draft.settings.whisperModel)
                    .accessibilityLabel("Whisper model")
            }

            Section("Subtitles") {
                Slider(value: $draft.settings.subtitleFontSize, in: 18...64, step: 1) {
                    Text("Font size")
                } minimumValueLabel: {
                    Text("18")
                } maximumValueLabel: {
                    Text("64")
                }

                Slider(value: $draft.settings.subtitleBackgroundOpacity, in: 0.2...0.9, step: 0.01) {
                    Text("Background opacity")
                } minimumValueLabel: {
                    Text("20%")
                } maximumValueLabel: {
                    Text("90%")
                }

                Toggle("Show bilingual subtitles", isOn: $draft.settings.showBilingualSubtitles)
            }

            Section("Languages") {
                TextField("Source language", text: $draft.settings.sourceLanguage)
                    .disabled(viewModel.isTranslationTestRunning)
                validationMessage(openAIValidation.sourceLanguageError)
                TextField("Target language", text: $draft.settings.targetLanguage)
                    .disabled(viewModel.isTranslationTestRunning)
                validationMessage(openAIValidation.targetLanguageError)
            }

            Section("Appearance") {
                Picker("Theme", selection: $draft.settings.theme) {
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
                        if await viewModel.save(draft.settings, apiKey: draft.apiKey) {
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
        .disabled(!isDraftLoaded)
        .overlay {
            if !isDraftLoaded {
                ProgressView("Loading settings…")
            }
        }
        .task {
            await viewModel.load()
            guard !Task.isCancelled else { return }
            draft = SettingsDraft(settings: viewModel.settings, apiKey: viewModel.apiKey)
            isDraftLoaded = true
            viewModel.resetTranslationTest()
        }
        .onChange(of: draft.apiKey) { _, _ in viewModel.resetTranslationTest() }
        .onChange(of: draft.settings.openAIModel) { _, _ in viewModel.resetTranslationTest() }
        .onChange(of: draft.settings.sourceLanguage) { _, _ in viewModel.resetTranslationTest() }
        .onChange(of: draft.settings.targetLanguage) { _, _ in viewModel.resetTranslationTest() }
        .onDisappear {
            translationTestTask?.cancel()
            translationTestTask = nil
        }
    }

    private var openAIValidation: OpenAISettingsValidation {
        OpenAISettingsValidation(apiKey: draft.apiKey, settings: draft.settings)
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
        switch draft.settings.audioCaptureBackend {
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

private struct SettingsDraft: Equatable {
    var settings = AppSettings()
    var apiKey = ""
}
