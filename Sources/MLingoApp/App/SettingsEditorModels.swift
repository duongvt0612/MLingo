import Foundation
import MLingoCore

enum SettingsDestination: String, CaseIterable, Identifiable, Sendable {
    case general
    case audioSpeech
    case aiProviders
    case models
    case translation
    case subtitles
    case appearance
    case privacy

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .audioSpeech: "Audio & Speech"
        case .aiProviders: "AI Providers"
        case .models: "Models"
        case .translation: "Translation"
        case .subtitles: "Subtitles"
        case .appearance: "Appearance"
        case .privacy: "Privacy"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .audioSpeech: "waveform"
        case .aiProviders: "server.rack"
        case .models: "shippingbox"
        case .translation: "character.book.closed"
        case .subtitles: "captions.bubble"
        case .appearance: "circle.lefthalf.filled"
        case .privacy: "hand.raised"
        }
    }
}

enum ProviderAuthenticationMode: String, CaseIterable, Identifiable, Sendable {
    case none
    case bearer
    case customHeader

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "None"
        case .bearer: "Bearer token"
        case .customHeader: "Custom secret header"
        }
    }
}

enum CredentialMutation: Equatable, Sendable {
    case replace(String)
    case remove
}

struct ProviderProfileDraft: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var kind: ProviderKind
    var endpoint: String
    var apiStyle: ProviderAPIStyle
    var authenticationMode: ProviderAuthenticationMode
    var customHeaderName: String
    var credentialID: CredentialID
    var models: [ModelCapability: [String]]
    var hasStoredCredential: Bool

    init(profile: ProviderProfile, hasStoredCredential: Bool) {
        id = profile.id
        name = profile.name
        kind = profile.kind
        endpoint = profile.endpoint?.absoluteString ?? ""
        apiStyle = profile.apiStyle
        models = profile.models
        self.hasStoredCredential = hasStoredCredential

        switch profile.authentication {
        case .none:
            authenticationMode = .none
            customHeaderName = "X-API-Key"
            credentialID = Self.defaultCredentialID(for: profile.id)
        case .bearer(let id):
            authenticationMode = .bearer
            customHeaderName = "X-API-Key"
            credentialID = id
        case .customHeader(let name, let id):
            authenticationMode = .customHeader
            customHeaderName = name
            credentialID = id
        }
    }

    init(profile: ProviderProfile) {
        self.init(profile: profile, hasStoredCredential: false)
    }

    var normalizedProfile: ProviderProfile {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            endpoint: trimmedEndpoint.isEmpty ? nil : URL(string: trimmedEndpoint),
            apiStyle: apiStyle,
            authentication: normalizedAuthentication,
            models: normalizedModels
        )
    }

    var referencedCredentialID: CredentialID? {
        authenticationMode == .none ? nil : credentialID
    }

    static func defaultCredentialID(for profileID: UUID) -> CredentialID {
        CredentialID("provider-\(profileID.uuidString.lowercased())")
    }

    private var normalizedAuthentication: ProviderAuthentication {
        switch authenticationMode {
        case .none:
            .none
        case .bearer:
            .bearer(credentialID: credentialID)
        case .customHeader:
            .customHeader(
                name: customHeaderName.trimmingCharacters(in: .whitespacesAndNewlines),
                credentialID: credentialID
            )
        }
    }

    private var normalizedModels: [ModelCapability: [String]] {
        models.reduce(into: [:]) { result, entry in
            var seen: Set<String> = []
            let values = entry.value.compactMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
                return trimmed
            }
            if !values.isEmpty {
                result[entry.key] = values
            }
        }
    }
}

enum SettingsDraftIssue: Equatable, Sendable {
    case invalidAppSettings(AppSettingsField, String)
    case invalidProfile(UUID, ProviderProfileValidationIssue)
    case invalidSelection(ModelCapability, ProviderResolutionIssue)
    case emptyCredentialReplacement(CredentialID)
}

struct SettingsDraftValidation: Equatable, Sendable {
    let normalizedAppSettings: AppSettings
    let normalizedProfiles: [ProviderProfile]
    let issues: [SettingsDraftIssue]

    var isValid: Bool { issues.isEmpty }
}

struct SettingsEditorDraft: Equatable, Sendable {
    var appSettings: AppSettings
    var profiles: [ProviderProfileDraft]
    var selections: [ModelCapability: CapabilitySelection]
    var overlaySelection: OverlayDisplaySelection
    var credentialMutations: [CredentialID: CredentialMutation]

    init(
        appSettings: AppSettings,
        profiles: [ProviderProfileDraft],
        selections: [ModelCapability: CapabilitySelection],
        overlaySelection: OverlayDisplaySelection,
        credentialMutations: [CredentialID: CredentialMutation] = [:]
    ) {
        self.appSettings = appSettings
        self.profiles = profiles
        self.selections = selections
        self.overlaySelection = overlaySelection
        self.credentialMutations = credentialMutations
    }

    var validation: SettingsDraftValidation {
        let appValidation = AppSettingsValidation(settings: appSettings)
        let normalizedProfiles = profiles.map(\.normalizedProfile)
        var issues = appValidation.errors.map {
            SettingsDraftIssue.invalidAppSettings($0.key, $0.value)
        }

        for profile in normalizedProfiles {
            issues.append(contentsOf: profile.validationIssues.map {
                .invalidProfile(profile.id, $0)
            })
        }

        let registry = ProviderRegistry(
            profiles: normalizedProfiles,
            selections: selections
        )
        for capability in ModelCapability.allCases where selections[capability] != nil {
            do {
                _ = try registry.resolve(capability)
            } catch let error as ProviderResolutionError {
                issues.append(.invalidSelection(capability, error.issue))
            } catch {
                assertionFailure("ProviderRegistry returned an unexpected error: \(error)")
            }
        }

        for (credentialID, mutation) in credentialMutations {
            if case .replace(let secret) = mutation,
               secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.emptyCredentialReplacement(credentialID))
            }
        }

        return SettingsDraftValidation(
            normalizedAppSettings: appValidation.normalizedSettings,
            normalizedProfiles: normalizedProfiles,
            issues: issues
        )
    }

    mutating func deleteProfile(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let credentialID = profiles[index].referencedCredentialID
        profiles.remove(at: index)
        selections = selections.filter { $0.value.profileID != id }

        guard let credentialID,
              !profiles.contains(where: { $0.referencedCredentialID == credentialID })
        else { return }
        credentialMutations[credentialID] = .remove
    }
}
