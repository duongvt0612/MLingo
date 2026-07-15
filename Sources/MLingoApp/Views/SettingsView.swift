import MLingoCore
import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: MLingoViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editor: SettingsEditorViewModel?
    @State private var loadingError: String?

    var body: some View {
        Group {
            if let editor {
                SettingsEditorContent(
                    viewModel: viewModel,
                    editor: editor,
                    dismiss: { dismiss() }
                )
            } else if let loadingError {
                ContentUnavailableView {
                    Label("Settings unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadingError)
                } actions: {
                    Button("Try Again") {
                        Task { await loadEditor() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                ProgressView("Loading settings…")
                    .controlSize(.large)
                    .accessibilityLabel("Loading MLingo settings")
            }
        }
        .frame(minWidth: 860, minHeight: 600)
        .task {
            await loadEditor()
        }
    }

    @MainActor
    private func loadEditor() async {
        loadingError = nil
        await viewModel.load()
        do {
            editor = try await viewModel.makeSettingsEditor()
        } catch {
            loadingError = error.localizedDescription
        }
    }
}

private struct SettingsEditorContent: View {
    @Bindable var viewModel: MLingoViewModel
    @Bindable var editor: SettingsEditorViewModel
    let dismiss: () -> Void
    @FocusState private var focusedAppField: AppSettingsField?

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(SettingsDestination.allCases, selection: $editor.selectedDestination) {
                    destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .tag(destination)
                }
                .navigationTitle("Settings")
                .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
                .accessibilityLabel("Settings categories")
            } detail: {
                destinationContent
                    .navigationTitle(editor.selectedDestination.title)
            }

            Divider()
            saveBar
        }
        .onDisappear {
            editor.cancelConnectionTest()
        }
        .onChange(of: editor.focusRequest) { _, request in
            guard case .appSettings(let field) = request?.target else { return }
            Task { @MainActor in
                await Task.yield()
                focusedAppField = field
            }
        }
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch editor.selectedDestination {
        case .general:
            generalPage
        case .audioSpeech:
            audioPage
        case .aiProviders:
            ProviderSettingsView(editor: editor)
        case .models:
            modelsPage
        case .translation:
            translationPage
        case .subtitles:
            subtitlesPage
        case .appearance:
            appearancePage
        case .privacy:
            privacyPage
        }
    }

    private var generalPage: some View {
        Form {
            Section("MLingo") {
                LabeledContent("Product", value: "MLingo")
                LabeledContent("Platform", value: "macOS 14 or newer")
            }
            Section("Settings behavior") {
                Label(
                    "Changes are kept in this window until you choose Save.",
                    systemImage: "square.and.pencil"
                )
                Label(
                    "Provider and model changes apply to the next translation session.",
                    systemImage: "arrow.clockwise"
                )
            }
        }
        .settingsFormStyle()
    }

    private var audioPage: some View {
        Form {
            Section {
                Picker(
                    "Capture audio using",
                    selection: $editor.draft.appSettings.audioCaptureBackend
                ) {
                    ForEach(AudioCaptureBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityLabel("Audio capture backend")
            } header: {
                Text("System audio capture")
            } footer: {
                Text(audioCaptureHelpText)
            }
        }
        .settingsFormStyle()
    }

    private var modelsPage: some View {
        Form {
            Section("Speech recognition") {
                TextField("Whisper model ID", text: $editor.draft.appSettings.whisperModel)
                    .accessibilityLabel("Whisper model identifier")
                    .focused($focusedAppField, equals: .whisperModel)
                appValidationMessage(for: .whisperModel)
            }
            Section {
                Label(
                    "Model downloads, verification, storage, and deletion arrive with Model Manager in Milestone 08.",
                    systemImage: "shippingbox"
                )
                .foregroundStyle(.secondary)
            }
        }
        .settingsFormStyle()
    }

    private var translationPage: some View {
        Form {
            Section("Languages") {
                TextField("Source language", text: $editor.draft.appSettings.sourceLanguage)
                    .focused($focusedAppField, equals: .sourceLanguage)
                appValidationMessage(for: .sourceLanguage)
                TextField("Target language", text: $editor.draft.appSettings.targetLanguage)
                    .focused($focusedAppField, equals: .targetLanguage)
                appValidationMessage(for: .targetLanguage)
            }
            Section("Provider assignment") {
                LabeledContent("Translation", value: translationAssignmentSummary)
                Button("Configure in AI Providers") {
                    editor.selectedDestination = .aiProviders
                }
                .accessibilityHint("Opens the capability assignments editor")
            }
        }
        .settingsFormStyle()
    }

    private var subtitlesPage: some View {
        Form {
            Section("Overlay") {
                Picker("Display", selection: $editor.draft.overlaySelection) {
                    Text("Automatic").tag(OverlayDisplaySelection.automatic)
                    ForEach(viewModel.overlayPresentationState.availableDisplays) { display in
                        Text(display.name).tag(OverlayDisplaySelection.display(id: display.id))
                    }
                    if let unavailableDisplaySelection {
                        Text("Unavailable display").tag(unavailableDisplaySelection)
                    }
                }
                .disabled(viewModel.isRunning)
                .accessibilityHint(
                    viewModel.isRunning
                        ? "Stop live translation to change the display here"
                        : "Choose the display used by the subtitle overlay"
                )
                Toggle(
                    "Show bilingual subtitles",
                    isOn: $editor.draft.appSettings.showBilingualSubtitles
                )
            }

            Section("Typography") {
                TextField("Font name", text: $editor.draft.appSettings.subtitleFontName)
                    .focused($focusedAppField, equals: .subtitleFontName)
                appValidationMessage(for: .subtitleFontName)
                settingsSlider(
                    "Font size",
                    value: $editor.draft.appSettings.subtitleFontSize,
                    range: 18...64,
                    step: 1,
                    minimum: "18",
                    maximum: "64"
                )
                .focused($focusedAppField, equals: .subtitleFontSize)
                appValidationMessage(for: .subtitleFontSize)
            }

            Section("Contrast") {
                settingsSlider(
                    "Background opacity",
                    value: $editor.draft.appSettings.subtitleBackgroundOpacity,
                    range: 0.2...0.9,
                    step: 0.01,
                    minimum: "20%",
                    maximum: "90%"
                )
                .focused($focusedAppField, equals: .subtitleBackgroundOpacity)
                appValidationMessage(for: .subtitleBackgroundOpacity)
                settingsSlider(
                    "Text opacity",
                    value: $editor.draft.appSettings.subtitleTextOpacity,
                    range: 0...1,
                    step: 0.01,
                    minimum: "0%",
                    maximum: "100%"
                )
                .focused($focusedAppField, equals: .subtitleTextOpacity)
                appValidationMessage(for: .subtitleTextOpacity)
            }
        }
        .settingsFormStyle()
    }

    private var appearancePage: some View {
        Form {
            Section("Color scheme") {
                Picker("Appearance", selection: $editor.draft.appSettings.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .settingsFormStyle()
    }

    private var privacyPage: some View {
        Form {
            Section("Audio and transcripts") {
                Label("Raw audio is processed in memory and is not stored.", systemImage: "waveform.badge.minus")
                Label("Session recording remains off until explicitly enabled in a later milestone.", systemImage: "record.circle")
            }
            Section("AI providers") {
                LabeledContent("Translation destination", value: viewModel.translationDestinationDescription)
                Label("Provider secrets are stored in Keychain, never in profile settings.", systemImage: "key")
                Label("MLingo never silently falls back between local and cloud providers.", systemImage: "arrow.triangle.branch")
            }
        }
        .settingsFormStyle()
    }

    private var saveBar: some View {
        HStack(spacing: 12) {
            if let saveError = editor.saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityLabel("Save failed: \(saveError)")
            } else if !editor.draft.validation.isValid {
                Label("Review the highlighted settings before saving.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel") {
                editor.discardChanges()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                Task {
                    if await editor.save() {
                        dismiss()
                    }
                }
            } label: {
                if editor.isSaving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                    }
                } else {
                    Text("Save")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(editor.isSaving)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func appValidationMessage(for field: AppSettingsField) -> some View {
        if let message = editor.draft.validation.issues.compactMap({ issue -> String? in
            guard case .invalidAppSettings(let issueField, let message) = issue,
                  issueField == field
            else { return nil }
            return message
        }).first {
            SettingsValidationMessage(message: message)
        }
    }

    private func settingsSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        minimum: String,
        maximum: String
    ) -> some View {
        Slider(value: value, in: range, step: step) {
            Text(title)
        } minimumValueLabel: {
            Text(minimum)
        } maximumValueLabel: {
            Text(maximum)
        }
    }

    private var unavailableDisplaySelection: OverlayDisplaySelection? {
        guard case .display(let displayID) = editor.draft.overlaySelection,
              !viewModel.overlayPresentationState.availableDisplays.contains(
                where: { $0.id == displayID }
              )
        else { return nil }
        return .display(id: displayID)
    }

    private var translationAssignmentSummary: String {
        guard let selection = editor.draft.selections[.translation],
              let profile = editor.draft.profiles.first(where: { $0.id == selection.profileID })
        else { return "Not configured" }
        return "\(profile.name) — \(selection.model)"
    }

    private var audioCaptureHelpText: String {
        switch editor.draft.appSettings.audioCaptureBackend {
        case .coreAudioTap:
            if #available(macOS 14.2, *) {
                "Captures system audio directly and requires System Audio Recording permission."
            } else {
                "Requires macOS 14.2 or newer. MLingo uses Screen Recording on this macOS version."
            }
        case .screenCaptureKit:
            "Captures system audio through ScreenCaptureKit and requires Screen Recording permission."
        }
    }
}

struct SettingsValidationMessage: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityLabel("Validation error: \(message)")
    }
}

private extension View {
    func settingsFormStyle() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(12)
    }
}
