import MLingoCore
import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: MLingoViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SettingsDraft()
    @State private var isDraftLoaded = false
    @State private var touchedFields: Set<AppSettingsField> = []
    @State private var didAttemptSettingsValidation = false
    @State private var didAttemptTranslationTest = false
    @State private var saveError: String?
    @State private var translationTestTask: Task<Void, Never>?
    @FocusState private var focusedField: SettingsFocusField?

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
                    .focused($focusedField, equals: .apiKey)
                validationMessage(
                    didAttemptTranslationTest ? openAIValidation.apiKeyError : nil
                )
                credentialStatus

                TextField("Model", text: $draft.settings.openAIModel)
                    .accessibilityLabel("OpenAI translation model")
                    .disabled(viewModel.isTranslationTestRunning)
                    .focused($focusedField, equals: .openAIModel)
                validationMessage(
                    settingsValidation.errors[.openAIModel],
                    field: .openAIModel
                )

                Text("Recommended default: gpt-5.4-mini")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    didAttemptTranslationTest = true
                    focusFirstTranslationError()
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
                .disabled(
                    viewModel.isActive
                        || viewModel.isTranslationTestRunning
                        || viewModel.isSavingSettings
                )
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
                    .focused($focusedField, equals: .whisperModel)
                validationMessage(
                    settingsValidation.errors[.whisperModel],
                    field: .whisperModel
                )
            }

            Section("Subtitles") {
                Picker("Overlay display", selection: $draft.overlayDisplaySelection) {
                    Text("Automatic").tag(OverlayDisplaySelection.automatic)
                    ForEach(viewModel.overlayPresentationState.availableDisplays) { display in
                        Text(display.name).tag(OverlayDisplaySelection.display(id: display.id))
                    }
                    if let unavailableDisplaySelection {
                        Text("Unavailable display")
                            .tag(unavailableDisplaySelection)
                    }
                }
                .disabled(viewModel.isRunning)
                .accessibilityLabel("Overlay display")
                .accessibilityHint(
                    viewModel.isRunning
                        ? "Stop live translation to change the display here, or use the overlay HUD"
                        : "Choose where subtitles appear"
                )

                Slider(value: $draft.settings.subtitleFontSize, in: 18...64, step: 1) {
                    Text("Font size")
                } minimumValueLabel: {
                    Text("18")
                } maximumValueLabel: {
                    Text("64")
                }
                .focused($focusedField, equals: .subtitleFontSize)
                validationMessage(
                    settingsValidation.errors[.subtitleFontSize],
                    field: .subtitleFontSize
                )

                TextField("Font name", text: $draft.settings.subtitleFontName)
                    .accessibilityLabel("Subtitle font name")
                    .focused($focusedField, equals: .subtitleFontName)
                validationMessage(
                    settingsValidation.errors[.subtitleFontName],
                    field: .subtitleFontName
                )

                Slider(value: $draft.settings.subtitleBackgroundOpacity, in: 0.2...0.9, step: 0.01) {
                    Text("Background opacity")
                } minimumValueLabel: {
                    Text("20%")
                } maximumValueLabel: {
                    Text("90%")
                }
                .focused($focusedField, equals: .subtitleBackgroundOpacity)
                validationMessage(
                    settingsValidation.errors[.subtitleBackgroundOpacity],
                    field: .subtitleBackgroundOpacity
                )

                Slider(value: $draft.settings.subtitleTextOpacity, in: 0...1, step: 0.01) {
                    Text("Text opacity")
                } minimumValueLabel: {
                    Text("0%")
                } maximumValueLabel: {
                    Text("100%")
                }
                .focused($focusedField, equals: .subtitleTextOpacity)
                validationMessage(
                    settingsValidation.errors[.subtitleTextOpacity],
                    field: .subtitleTextOpacity
                )

                Toggle("Show bilingual subtitles", isOn: $draft.settings.showBilingualSubtitles)
            }

            Section("Languages") {
                TextField("Source language", text: $draft.settings.sourceLanguage)
                    .disabled(viewModel.isTranslationTestRunning)
                    .focused($focusedField, equals: .sourceLanguage)
                validationMessage(
                    settingsValidation.errors[.sourceLanguage],
                    field: .sourceLanguage
                )
                TextField("Target language", text: $draft.settings.targetLanguage)
                    .disabled(viewModel.isTranslationTestRunning)
                    .focused($focusedField, equals: .targetLanguage)
                validationMessage(
                    settingsValidation.errors[.targetLanguage],
                    field: .targetLanguage
                )
            }

            Section("Appearance") {
                Picker("Theme", selection: $draft.settings.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue.capitalized).tag(theme)
                    }
                }
            }

            HStack {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Save failed: \(saveError)")
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button {
                    didAttemptSettingsValidation = true
                    saveError = nil
                    guard settingsValidation.isValid else {
                        focusFirstSettingsError()
                        return
                    }
                    Task {
                        if await viewModel.save(
                            draft.settings,
                            apiKey: draft.apiKey,
                            overlayDisplaySelection: draft.overlayDisplaySelection
                        ) {
                            dismiss()
                        } else {
                            saveError = viewModel.lastError
                        }
                    }
                } label: {
                    if viewModel.isSavingSettings {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Saving…")
                        }
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
        .disabled(!isDraftLoaded || viewModel.isSavingSettings)
        .overlay {
            if !isDraftLoaded {
                ProgressView("Loading settings…")
            }
        }
        .task {
            await viewModel.load()
            guard !Task.isCancelled else { return }
            draft = SettingsDraft(
                settings: viewModel.settings,
                apiKey: viewModel.apiKey,
                overlayDisplaySelection: viewModel.overlayPresentationState.selectedDisplay
            )
            touchedFields.removeAll()
            isDraftLoaded = true
            viewModel.resetTranslationTest()
        }
        .onChange(of: draft.apiKey) { _, _ in
            guard isDraftLoaded else { return }
            viewModel.resetTranslationTest()
        }
        .onChange(of: draft.settings.whisperModel) { _, _ in markEdited(.whisperModel) }
        .onChange(of: draft.settings.openAIModel) { _, _ in markEdited(.openAIModel, resetsTest: true) }
        .onChange(of: draft.settings.subtitleFontName) { _, _ in markEdited(.subtitleFontName) }
        .onChange(of: draft.settings.subtitleFontSize) { _, _ in markEdited(.subtitleFontSize) }
        .onChange(of: draft.settings.subtitleBackgroundOpacity) { _, _ in markEdited(.subtitleBackgroundOpacity) }
        .onChange(of: draft.settings.subtitleTextOpacity) { _, _ in markEdited(.subtitleTextOpacity) }
        .onChange(of: draft.settings.sourceLanguage) { _, _ in markEdited(.sourceLanguage, resetsTest: true) }
        .onChange(of: draft.settings.targetLanguage) { _, _ in markEdited(.targetLanguage, resetsTest: true) }
        .onChange(of: viewModel.overlayPresentationState.selectedDisplay) { _, selection in
            if viewModel.isRunning {
                draft.overlayDisplaySelection = selection
            }
        }
        .onDisappear {
            translationTestTask?.cancel()
            translationTestTask = nil
        }
    }

    private var openAIValidation: OpenAISettingsValidation {
        OpenAISettingsValidation(apiKey: draft.apiKey, settings: draft.settings)
    }

    private var settingsValidation: AppSettingsValidation {
        AppSettingsValidation(settings: draft.settings)
    }

    private var unavailableDisplaySelection: OverlayDisplaySelection? {
        guard case .display(let displayID) = draft.overlayDisplaySelection,
              !viewModel.overlayPresentationState.availableDisplays.contains(
                  where: { $0.id == displayID }
              )
        else {
            return nil
        }
        return .display(id: displayID)
    }

    @ViewBuilder
    private func validationMessage(
        _ message: String?,
        field: AppSettingsField? = nil
    ) -> some View {
        let shouldShow = field.map {
            touchedFields.contains($0)
                || didAttemptSettingsValidation
                || (didAttemptTranslationTest && isTranslationTestField($0))
        } ?? true
        if shouldShow, let message {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel("Validation error: \(message)")
        }
    }

    @ViewBuilder
    private var credentialStatus: some View {
        let status = viewModel.credentialStatus(for: draft.apiKey)
        Label(status.message, systemImage: credentialStatusIcon(status))
            .font(.caption)
            .foregroundStyle(credentialStatusColor(status))
            .accessibilityLabel("API key status: \(status.message)")
    }

    private func credentialStatusIcon(_ status: CredentialStatus) -> String {
        switch status {
        case .checking:
            "clock"
        case .notSaved:
            "key.slash"
        case .saved:
            "checkmark.circle"
        case .unsavedChange:
            "pencil.circle"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    private func credentialStatusColor(_ status: CredentialStatus) -> Color {
        switch status {
        case .saved:
            .green
        case .unsavedChange:
            .orange
        case .failed:
            .red
        case .checking, .notSaved:
            .secondary
        }
    }

    private func markEdited(_ field: AppSettingsField, resetsTest: Bool = false) {
        guard isDraftLoaded else { return }
        touchedFields.insert(field)
        if resetsTest {
            viewModel.resetTranslationTest()
        }
    }

    private func focusFirstSettingsError() {
        guard let field = AppSettingsField.allCases.first(
            where: { settingsValidation.errors[$0] != nil }
        ) else { return }
        focusedField = SettingsFocusField(field)
    }

    private func focusFirstTranslationError() {
        if openAIValidation.apiKeyError != nil {
            focusedField = .apiKey
        } else if openAIValidation.modelError != nil {
            focusedField = .openAIModel
        }
    }

    private func isTranslationTestField(_ field: AppSettingsField) -> Bool {
        field == .openAIModel
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
    var overlayDisplaySelection = OverlayDisplaySelection.automatic
}

private enum SettingsFocusField: Hashable {
    case apiKey
    case whisperModel
    case openAIModel
    case subtitleFontName
    case subtitleFontSize
    case subtitleBackgroundOpacity
    case subtitleTextOpacity
    case sourceLanguage
    case targetLanguage

    init(_ field: AppSettingsField) {
        switch field {
        case .whisperModel:
            self = .whisperModel
        case .openAIModel:
            self = .openAIModel
        case .subtitleFontName:
            self = .subtitleFontName
        case .subtitleFontSize:
            self = .subtitleFontSize
        case .subtitleBackgroundOpacity:
            self = .subtitleBackgroundOpacity
        case .subtitleTextOpacity:
            self = .subtitleTextOpacity
        case .sourceLanguage:
            self = .sourceLanguage
        case .targetLanguage:
            self = .targetLanguage
        }
    }
}
