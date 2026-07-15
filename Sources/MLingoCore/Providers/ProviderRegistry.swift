import Foundation

public struct CapabilitySelection: Codable, Equatable, Sendable {
    public let profileID: UUID
    public let model: String

    public init(profileID: UUID, model: String) {
        self.profileID = profileID
        self.model = model
    }
}

public struct ResolvedProviderSelection: Equatable, Sendable {
    public let capability: ModelCapability
    public let profile: ProviderProfile
    public let model: String

    public init(
        capability: ModelCapability,
        profile: ProviderProfile,
        model: String
    ) {
        self.capability = capability
        self.profile = profile
        self.model = model
    }
}

public enum ProviderResolutionIssue: Equatable, Sendable {
    case selectionMissing(ModelCapability)
    case profileNotFound(UUID)
    case invalidProfile(UUID, ProviderProfileValidationIssue)
    case capabilityUnsupported(UUID, ModelCapability)
    case modelUnavailable(UUID, ModelCapability, String)
}

public enum ProviderRecoveryAction: Equatable, Sendable {
    case selectProvider(ModelCapability)
    case editProfile(UUID)
    case selectModel(ModelCapability)
}

public struct ProviderResolutionError: Error, Equatable, Sendable {
    public let issue: ProviderResolutionIssue
    public let recoveryAction: ProviderRecoveryAction

    public init(
        issue: ProviderResolutionIssue,
        recoveryAction: ProviderRecoveryAction
    ) {
        self.issue = issue
        self.recoveryAction = recoveryAction
    }
}

public struct ProviderRegistry: Sendable {
    private let profilesByID: [UUID: ProviderProfile]
    private let selections: [ModelCapability: CapabilitySelection]

    public init(
        profiles: [ProviderProfile],
        selections: [ModelCapability: CapabilitySelection]
    ) {
        profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        self.selections = selections
    }

    public func resolve(
        _ capability: ModelCapability
    ) throws -> ResolvedProviderSelection {
        guard let selection = selections[capability] else {
            throw ProviderResolutionError(
                issue: .selectionMissing(capability),
                recoveryAction: .selectProvider(capability)
            )
        }
        guard let profile = profilesByID[selection.profileID] else {
            throw ProviderResolutionError(
                issue: .profileNotFound(selection.profileID),
                recoveryAction: .selectProvider(capability)
            )
        }
        if let issue = profile.validationIssues.first {
            throw ProviderResolutionError(
                issue: .invalidProfile(profile.id, issue),
                recoveryAction: .editProfile(profile.id)
            )
        }
        guard let models = profile.models[capability] else {
            throw ProviderResolutionError(
                issue: .capabilityUnsupported(profile.id, capability),
                recoveryAction: .selectProvider(capability)
            )
        }
        let model = selection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard models.contains(model) else {
            throw ProviderResolutionError(
                issue: .modelUnavailable(profile.id, capability, model),
                recoveryAction: .selectModel(capability)
            )
        }
        return ResolvedProviderSelection(
            capability: capability,
            profile: profile,
            model: model
        )
    }
}
