import AppKit
import MLingoCore
import SwiftUI

/// The Models pane: what is installed, what it costs, and what to do when something goes wrong.
///
/// Downloads and deletions apply immediately, unlike everything else in Settings. The one value
/// that stays transactional is the Hugging Face token, which lives in the settings draft and is
/// only written to Keychain on Save — so downloads are held back while an unsaved token is
/// pending rather than silently using the old one.
struct ModelsSettingsView: View {
    @Bindable var viewModel: MLingoViewModel
    @Bindable var editor: SettingsEditorViewModel
    @FocusState.Binding var focusedAppField: AppSettingsField?
    @State private var catalog: ModelsCatalogViewModel?
    @FocusState private var tokenFieldFocused: Bool

    private var tokenCredentialID: CredentialID { ModelManager.huggingFaceCredentialID }

    private var hasPendingTokenChange: Bool {
        editor.draft.credentialMutations[tokenCredentialID] != nil
    }

    var body: some View {
        Form {
            speechRecognitionSection
            if let catalog {
                catalogSection(catalog)
                tokenSection
                storageSection(catalog)
            } else {
                storageUnavailableSection
            }
        }
        .settingsFormStyle()
        .task { await prepareCatalog() }
        .onDisappear { catalog?.stop() }
        .onAppear { applyFocusRequest(editor.focusRequest) }
        .onChange(of: editor.focusRequest) { _, request in applyFocusRequest(request) }
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionPrompt,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                Task { await catalog?.confirmDeletion() }
            }
            Button("Cancel", role: .cancel) { catalog?.cancelDeletion() }
        } message: {
            Text("The files are removed from disk. You can download the model again later.")
        }
    }

    // MARK: - Speech recognition

    private var speechRecognitionSection: some View {
        Section("Speech recognition") {
            TextField("Whisper model ID", text: $editor.draft.appSettings.whisperModel)
                .accessibilityLabel("Whisper model identifier")
                .focused($focusedAppField, equals: .whisperModel)
            if let message = validationMessage(for: .whisperModel) {
                SettingsValidationMessage(message: message)
            }
            Text("An installed model is used from local storage. Any other identifier is downloaded by the speech engine as before.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Catalog

    private func catalogSection(_ catalog: ModelsCatalogViewModel) -> some View {
        Section("Model catalog") {
            ForEach(catalog.rows) { row in
                modelRow(row, catalog: catalog)
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ row: ModelsCatalogViewModel.Row, catalog: ModelsCatalogViewModel) -> some View {
        let presentation = row.presentation
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.entry.displayName)
                        .font(.headline)
                    Text("\(row.entry.role.displayName) · \(row.entry.repository) · \(row.entry.shortRevision)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(sizeSummary(row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Size \(sizeSummary(row))")
            }

            Label(presentation.title, systemImage: presentation.systemImage)
                .foregroundStyle(presentation.isError ? Color.red : Color.secondary)
                .accessibilityLabel("Status: \(presentation.accessibilityLabel)")

            if let fraction = presentation.progressFraction {
                ProgressView(value: fraction)
                    .accessibilityLabel("Download progress for \(row.entry.displayName)")
                    .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
            } else if row.state.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working on \(row.entry.displayName)")
            } else if let detail = presentation.detail, !presentation.isError {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = row.errorMessage {
                SettingsValidationMessage(message: message)
                if let action = row.recoveryAction {
                    Button(action.title) { catalog.recover(row.id) }
                        .accessibilityHint("Recovery action for \(row.entry.displayName)")
                }
            }

            rowActions(row, catalog: catalog)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.entry.displayName)
    }

    @ViewBuilder
    private func rowActions(_ row: ModelsCatalogViewModel.Row, catalog: ModelsCatalogViewModel) -> some View {
        let downloadDisabledReason = ModelActionAvailability.downloadDisabledReason(
            state: row.state,
            hasPendingTokenChange: hasPendingTokenChange
        )
        let deleteDisabledReason = ModelActionAvailability.deleteDisabledReason(
            state: row.state,
            isSessionRunning: viewModel.isRunning
        )

        HStack(spacing: 10) {
            if ModelActionAvailability.isCancellable(row.state) {
                Button("Cancel") { catalog.cancel(row.id) }
                    .accessibilityLabel("Cancel download of \(row.entry.displayName)")
            } else {
                Button(row.state.isUsable ? "Redownload" : "Download") {
                    catalog.download(row.id)
                }
                .disabled(downloadDisabledReason != nil)
                .accessibilityLabel("Download \(row.entry.displayName)")
            }

            if row.entry.role == .speechRecognition, row.state.isUsable {
                Button("Use This Model") {
                    editor.draft.appSettings.whisperModel = row.id.rawValue
                }
                .accessibilityHint("Sets the Whisper model identifier to this model")
            }

            Spacer()

            Button("Delete", role: .destructive) { catalog.requestDeletion(row.id) }
                .disabled(deleteDisabledReason != nil)
                .accessibilityLabel("Delete \(row.entry.displayName)")
        }

        // Only the reason for a control the user could otherwise expect to work: "not on disk"
        // next to every uninstalled model would be noise.
        if let reason = downloadDisabledReason, !row.state.isBusy {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if row.state.isUsable, let reason = deleteDisabledReason {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Token

    private var tokenSection: some View {
        Section {
            switch editor.draft.credentialMutations[tokenCredentialID] {
            case .replace:
                SecureField("Hugging Face token", text: tokenBinding)
                    .textContentType(.password)
                    .focused($tokenFieldFocused)
                HStack {
                    Label("Unsaved token, applies after Save", systemImage: "pencil.circle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel Change") {
                        editor.draft.credentialMutations[tokenCredentialID] = nil
                    }
                }
            case .remove:
                HStack {
                    Label("Token will be removed on Save", systemImage: "key.slash")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Undo") { editor.draft.credentialMutations[tokenCredentialID] = nil }
                }
            case nil:
                HStack {
                    Label(
                        hasStoredToken ? "••••••••  Saved in Keychain" : "No token saved",
                        systemImage: hasStoredToken ? "checkmark.circle" : "circle.dashed"
                    )
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(hasStoredToken ? "Replace" : "Add") {
                        editor.draft.credentialMutations[tokenCredentialID] = .replace("")
                        tokenFieldFocused = true
                    }
                    if hasStoredToken {
                        Button("Remove", role: .destructive) {
                            editor.draft.credentialMutations[tokenCredentialID] = .remove
                        }
                    }
                }
            }
        } header: {
            Text("Hugging Face token")
        } footer: {
            Text("Only needed for gated or private repositories. The token is stored in Keychain and never written to settings or logs.")
        }
    }

    private var hasStoredToken: Bool {
        editor.snapshot.credentialPresence[tokenCredentialID] == true
    }

    private var tokenBinding: Binding<String> {
        Binding(
            get: {
                guard case .replace(let secret) =
                    editor.draft.credentialMutations[tokenCredentialID]
                else { return "" }
                return secret
            },
            set: { editor.draft.credentialMutations[tokenCredentialID] = .replace($0) }
        )
    }

    // MARK: - Storage

    private func storageSection(_ catalog: ModelsCatalogViewModel) -> some View {
        Section("Storage") {
            if let usage = catalog.usage {
                LabeledContent("Installed models", value: formatted(usage.installedBytes))
                LabeledContent("Download cache", value: formatted(usage.hubCacheBytes))
                if usage.quarantineBytes > 0 {
                    LabeledContent("Quarantined downloads", value: formatted(usage.quarantineBytes))
                }
                LabeledContent("Total on disk", value: formatted(usage.totalBytes))
            }
            if let root = viewModel.modelStorageRoot {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([root])
                }
                .accessibilityHint("Opens the model storage folder")
            }
        }
    }

    private var storageUnavailableSection: some View {
        Section("Model catalog") {
            Label(
                "MLingo could not open its model storage folder, so models cannot be managed here.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.red)
            Text("Speech recognition still downloads models the previous way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Plumbing

    private func prepareCatalog() async {
        guard catalog == nil, let manager = viewModel.modelCatalogManager else { return }
        let created = ModelsCatalogViewModel(
            manager: manager,
            performExternalCommand: { command in perform(command) }
        )
        catalog = created
        await created.start()
    }

    private func perform(_ command: ModelRecoveryCommand) {
        switch command {
        case .focusToken:
            if editor.draft.credentialMutations[tokenCredentialID] == nil {
                editor.draft.credentialMutations[tokenCredentialID] = .replace("")
            }
            tokenFieldFocused = true
        case .openPage(let url):
            NSWorkspace.shared.open(url)
        case .stopSession:
            viewModel.stop()
        case .revealStorage:
            if let root = viewModel.modelStorageRoot {
                NSWorkspace.shared.activateFileViewerSelecting([root])
            }
        case .copyDiagnostics(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .retry:
            // Handled inside the view model; nothing here needs the app's help.
            break
        }
    }

    private func applyFocusRequest(_ request: SettingsFocusRequest?) {
        guard case .huggingFaceToken = request?.target else { return }
        tokenFieldFocused = true
    }

    private var deletionPrompt: Binding<Bool> {
        Binding(
            get: { catalog?.pendingDeletion != nil },
            set: { isPresented in
                if !isPresented { catalog?.cancelDeletion() }
            }
        )
    }

    private var deletionTitle: String {
        guard let id = catalog?.pendingDeletion,
              let row = catalog?.rows.first(where: { $0.id == id })
        else { return "Delete this model?" }
        return "Delete \(row.entry.displayName)?"
    }

    private func sizeSummary(_ row: ModelsCatalogViewModel.Row) -> String {
        if let installed = row.installedBytes, installed > 0 {
            return formatted(installed)
        }
        return "\(formatted(row.entry.expectedBytes)) download"
    }

    private func validationMessage(for field: AppSettingsField) -> String? {
        editor.draft.validation.issues.compactMap { issue -> String? in
            guard case .invalidAppSettings(let issueField, let message) = issue,
                  issueField == field
            else { return nil }
            return message
        }.first
    }

    private func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
