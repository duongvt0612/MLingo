import MLingoCore
import SwiftUI

private enum ProviderMasterSelection: Hashable {
    case assignments
    case profile(UUID)
}

struct ProviderSettingsView: View {
    @Bindable var editor: SettingsEditorViewModel
    @State private var selection: ProviderMasterSelection = .assignments

    var body: some View {
        HSplitView {
            providerList
                .frame(minWidth: 210, idealWidth: 230, maxWidth: 280)
            detail
                .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selection) { _, _ in
            editor.cancelConnectionTest()
        }
    }

    private var providerList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Label("Capability Assignments", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(ProviderMasterSelection.assignments)

                Section("Profiles") {
                    ForEach(editor.draft.profiles) { profile in
                        Label(profile.name.isEmpty ? "Untitled Provider" : profile.name,
                              systemImage: profile.kind.systemImage)
                            .tag(ProviderMasterSelection.profile(profile.id))
                    }
                }
            }
            .accessibilityLabel("Provider profiles and capability assignments")

            Divider()
            HStack {
                Menu {
                    addProfileButton(.openAI)
                    addProfileButton(.ollama)
                    addProfileButton(.lmStudio)
                    addProfileButton(.custom)
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .accessibilityHint("Creates an unsaved provider profile from a preset")
                Spacer()
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .assignments:
            CapabilityAssignmentsView(editor: editor)
        case .profile(let id):
            ProviderProfileEditor(
                editor: editor,
                profileID: id,
                onDeleted: { selection = .assignments }
            )
        }
    }

    private func addProfileButton(_ kind: ProviderKind) -> some View {
        Button {
            let id = editor.addProfile(kind: kind)
            selection = .profile(id)
        } label: {
            Label(kind.displayName, systemImage: kind.systemImage)
        }
    }
}

private struct CapabilityAssignmentsView: View {
    @Bindable var editor: SettingsEditorViewModel
    private let capabilities: [ModelCapability] = [
        .translation,
        .chat,
        .embedding,
        .textToSpeech,
    ]

    var body: some View {
        Form {
            Section {
                Text("Choose a provider and model independently for each capability. Not configured is valid and never triggers fallback.")
                    .foregroundStyle(.secondary)
            }
            ForEach(capabilities, id: \.self) { capability in
                capabilitySection(capability)
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .navigationTitle("Capability Assignments")
    }

    @ViewBuilder
    private func capabilitySection(_ capability: ModelCapability) -> some View {
        Section {
            Picker("Provider", selection: profileBinding(for: capability)) {
                Text("Not configured").tag(Optional<UUID>.none)
                ForEach(availableProfiles(for: capability)) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
                if let unavailable = unavailableProfile(for: capability) {
                    Text("Unavailable: \(unavailable.name)").tag(Optional(unavailable.id))
                }
            }

            if let profile = selectedProfile(for: capability) {
                Picker("Model", selection: modelBinding(for: capability)) {
                    ForEach(profile.normalizedProfile.models[capability] ?? [], id: \.self) {
                        Text($0).tag($0)
                    }
                    if let selection = editor.draft.selections[capability],
                       !(profile.normalizedProfile.models[capability] ?? []).contains(selection.model) {
                        Text("Unavailable: \(selection.model)").tag(selection.model)
                    }
                }
            }

            if let message = selectionError(for: capability) {
                SettingsValidationMessage(message: message)
            }
        } header: {
            Label(capability.displayName, systemImage: capability.systemImage)
        }
    }

    private func availableProfiles(for capability: ModelCapability) -> [ProviderProfileDraft] {
        editor.draft.profiles.filter {
            !($0.normalizedProfile.models[capability] ?? []).isEmpty
        }
    }

    private func selectedProfile(for capability: ModelCapability) -> ProviderProfileDraft? {
        guard let id = editor.draft.selections[capability]?.profileID else { return nil }
        return editor.draft.profiles.first(where: { $0.id == id })
    }

    private func unavailableProfile(for capability: ModelCapability) -> ProviderProfileDraft? {
        guard let profile = selectedProfile(for: capability),
              !availableProfiles(for: capability).contains(where: { $0.id == profile.id })
        else { return nil }
        return profile
    }

    private func profileBinding(for capability: ModelCapability) -> Binding<UUID?> {
        Binding(
            get: { editor.draft.selections[capability]?.profileID },
            set: { editor.assign(profileID: $0, to: capability) }
        )
    }

    private func modelBinding(for capability: ModelCapability) -> Binding<String> {
        Binding(
            get: { editor.draft.selections[capability]?.model ?? "" },
            set: { model in
                guard let profileID = editor.draft.selections[capability]?.profileID else { return }
                editor.draft.selections[capability] = CapabilitySelection(
                    profileID: profileID,
                    model: model
                )
            }
        )
    }

    private func selectionError(for capability: ModelCapability) -> String? {
        editor.draft.validation.issues.compactMap { issue -> String? in
            guard case .invalidSelection(let issueCapability, let resolutionIssue) = issue,
                  issueCapability == capability
            else { return nil }
            return resolutionIssue.settingsMessage
        }.first
    }
}

private struct ProviderProfileEditor: View {
    @Bindable var editor: SettingsEditorViewModel
    let profileID: UUID
    let onDeleted: () -> Void
    @State private var confirmsDeletion = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case endpoint
        case customHeader
        case secret
    }

    var body: some View {
        if let index = editor.draft.profiles.firstIndex(where: { $0.id == profileID }) {
            profileForm(profile: $editor.draft.profiles[index])
        } else {
            ContentUnavailableView("Provider unavailable", systemImage: "server.rack")
        }
    }

    private func profileForm(profile: Binding<ProviderProfileDraft>) -> some View {
        Form {
            Section("Profile") {
                TextField("Name", text: profile.name)
                    .focused($focusedField, equals: .name)
                Picker("Provider kind", selection: profile.kind) {
                    ForEach(ProviderKind.remoteSettingsKinds, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
            }

            Section("API") {
                TextField("Endpoint", text: profile.endpoint)
                    .focused($focusedField, equals: .endpoint)
                    .accessibilityHint("Remote endpoints require HTTPS; HTTP is allowed only for localhost")
                Picker("API style", selection: profile.apiStyle) {
                    Text("Responses").tag(ProviderAPIStyle.responses)
                    Text("Chat Completions").tag(ProviderAPIStyle.chatCompletions)
                }
            }

            Section("Authentication") {
                Picker("Method", selection: profile.authenticationMode) {
                    ForEach(ProviderAuthenticationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                if profile.wrappedValue.authenticationMode == .customHeader {
                    TextField("Header name", text: profile.customHeaderName)
                        .focused($focusedField, equals: .customHeader)
                }
                if profile.wrappedValue.authenticationMode != .none {
                    credentialControls(profile: profile)
                }
            }

            ForEach(ModelCapability.providerSettingsCapabilities, id: \.self) { capability in
                Section("\(capability.displayName) models") {
                    TextField(
                        "Comma-separated model IDs",
                        text: modelsBinding(profile: profile, capability: capability)
                    )
                    .accessibilityLabel("\(capability.displayName) model identifiers")
                    if !editor.discoveredModels.isEmpty {
                        Menu("Add discovered model") {
                            ForEach(editor.discoveredModels, id: \.self) { model in
                                Button(model) {
                                    addDiscoveredModel(
                                        model,
                                        profile: profile,
                                        capability: capability
                                    )
                                }
                            }
                        }
                    }
                }
            }

            profileValidation(profile.wrappedValue)

            Section {
                HStack {
                    Button {
                        editor.startConnectionTest(profileID: profileID)
                    } label: {
                        Label(
                            isTesting ? "Testing…" : "Test Connection",
                            systemImage: "network"
                        )
                    }
                    .disabled(isTesting || !profile.wrappedValue.normalizedProfile.validationIssues.isEmpty)
                    .accessibilityHint("Tests this unsaved draft without persisting it")

                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        confirmsDeletion = true
                    } label: {
                        Label("Delete Profile", systemImage: "trash")
                    }
                }
                connectionFeedback
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .confirmationDialog(
            "Delete \(profile.wrappedValue.name.isEmpty ? "this profile" : profile.wrappedValue.name)?",
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive) {
                editor.deleteProfile(id: profileID)
                onDeleted()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deletionMessage)
        }
    }

    @ViewBuilder
    private func credentialControls(profile: Binding<ProviderProfileDraft>) -> some View {
        let id = profile.wrappedValue.credentialID
        switch editor.draft.credentialMutations[id] {
        case .replace:
            SecureField("New secret", text: replacementSecretBinding(id: id))
                .textContentType(.password)
                .focused($focusedField, equals: .secret)
            HStack {
                Label("Unsaved replacement", systemImage: "pencil.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel Replacement") {
                    editor.draft.credentialMutations[id] = nil
                }
            }
        case .remove:
            HStack {
                Label("Credential will be removed", systemImage: "key.slash")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Undo") {
                    editor.draft.credentialMutations[id] = nil
                }
            }
        case nil:
            HStack {
                Label(
                    profile.wrappedValue.hasStoredCredential
                        ? "••••••••  Saved in Keychain"
                        : "Credential missing",
                    systemImage: profile.wrappedValue.hasStoredCredential
                        ? "checkmark.circle"
                        : "exclamationmark.circle"
                )
                .foregroundStyle(
                    profile.wrappedValue.hasStoredCredential
                        ? Color.secondary
                        : Color.orange
                )
                Spacer()
                Button(profile.wrappedValue.hasStoredCredential ? "Replace" : "Add") {
                    editor.draft.credentialMutations[id] = .replace("")
                    focusedField = .secret
                }
                if profile.wrappedValue.hasStoredCredential {
                    Button("Remove", role: .destructive) {
                        editor.draft.credentialMutations[id] = .remove
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func profileValidation(_ profile: ProviderProfileDraft) -> some View {
        let messages = editor.draft.validation.issues.compactMap { issue -> String? in
            switch issue {
            case .invalidProfile(let id, let validationIssue) where id == profile.id:
                validationIssue.settingsMessage
            case .emptyCredentialReplacement(let id) where id == profile.credentialID:
                "Enter a non-empty replacement secret."
            default:
                nil
            }
        }
        if !messages.isEmpty {
            Section("Needs attention") {
                ForEach(messages, id: \.self) { message in
                    SettingsValidationMessage(message: message)
                }
            }
        }
    }

    @ViewBuilder
    private var connectionFeedback: some View {
        switch editor.connectionTestState {
        case .idle, .running:
            EmptyView()
        case .success(let id, let message, let models) where id == profileID:
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if !models.isEmpty {
                    Text("Discovered \(models.count) model(s). Add them explicitly above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        case .failure(let id, let message) where id == profileID:
            SettingsValidationMessage(message: message)
        default:
            EmptyView()
        }
    }

    private var isTesting: Bool {
        editor.connectionTestState == .running(profileID: profileID)
    }

    private var deletionMessage: String {
        let affected = ModelCapability.allCases.filter {
            editor.draft.selections[$0]?.profileID == profileID
        }.map(\.displayName)
        if affected.isEmpty {
            return "The profile and its unreferenced credential will be removed when you save."
        }
        return "This also clears: \(affected.joined(separator: ", ")). The unreferenced credential will be removed when you save."
    }

    private func replacementSecretBinding(id: CredentialID) -> Binding<String> {
        Binding(
            get: {
                guard case .replace(let secret) = editor.draft.credentialMutations[id] else {
                    return ""
                }
                return secret
            },
            set: { editor.draft.credentialMutations[id] = .replace($0) }
        )
    }

    private func modelsBinding(
        profile: Binding<ProviderProfileDraft>,
        capability: ModelCapability
    ) -> Binding<String> {
        Binding(
            get: { (profile.wrappedValue.models[capability] ?? []).joined(separator: ", ") },
            set: { text in
                profile.wrappedValue.models[capability] = text.split(separator: ",", omittingEmptySubsequences: false)
                    .map(String.init)
            }
        )
    }

    private func addDiscoveredModel(
        _ model: String,
        profile: Binding<ProviderProfileDraft>,
        capability: ModelCapability
    ) {
        var models = profile.wrappedValue.models[capability] ?? []
        guard !models.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .contains(model) else { return }
        models.append(model)
        profile.wrappedValue.models[capability] = models
    }
}
