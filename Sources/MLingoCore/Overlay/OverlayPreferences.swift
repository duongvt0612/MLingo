import Foundation

public enum OverlayDisplaySelection: Codable, Equatable, Sendable {
    case automatic
    case display(id: String)
}

public struct OverlayDisplayDescriptor: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let visibleFrame: CGRect
    public let isMain: Bool

    public init(
        id: String,
        name: String,
        visibleFrame: CGRect,
        isMain: Bool
    ) {
        self.id = id
        self.name = name
        self.visibleFrame = visibleFrame
        self.isMain = isMain
    }
}

public struct OverlayPlacement: Codable, Equatable, Sendable {
    public var normalizedCenterX: Double
    public var normalizedBottomY: Double

    public init(normalizedCenterX: Double, normalizedBottomY: Double) {
        self.normalizedCenterX = normalizedCenterX
        self.normalizedBottomY = normalizedBottomY
    }
}

public struct OverlayPreferences: Codable, Equatable, Sendable {
    public var selectedDisplay: OverlayDisplaySelection
    public var placementsByDisplayID: [String: OverlayPlacement]

    public init(
        selectedDisplay: OverlayDisplaySelection = .automatic,
        placementsByDisplayID: [String: OverlayPlacement] = [:]
    ) {
        self.selectedDisplay = selectedDisplay
        self.placementsByDisplayID = placementsByDisplayID
    }
}

public protocol OverlayPreferencesStoreProtocol: Sendable {
    func load() -> OverlayPreferences
    func save(_ preferences: OverlayPreferences)
}

public final class UserDefaultsOverlayPreferencesStore: OverlayPreferencesStoreProtocol,
    @unchecked Sendable
{
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        key: String = "com.duongvt.MLingo.overlayPreferences"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> OverlayPreferences {
        guard let data = defaults.data(forKey: key) else { return OverlayPreferences() }
        do {
            return try decoder.decode(OverlayPreferences.self, from: data)
        } catch {
            defaults.removeObject(forKey: key)
            MLingoLogger.overlay.warning("Reset malformed overlay preferences")
            return OverlayPreferences()
        }
    }

    public func save(_ preferences: OverlayPreferences) {
        do {
            defaults.set(try encoder.encode(preferences), forKey: key)
        } catch {
            MLingoLogger.overlay.error("Failed to encode overlay preferences")
        }
    }
}

enum OverlayDisplayResolver {
    static func resolve(
        selection: OverlayDisplaySelection,
        displays: [OverlayDisplayDescriptor],
        appWindowDisplayID: String?
    ) -> OverlayDisplayDescriptor? {
        if case .display(let id) = selection,
           let selected = displays.first(where: { $0.id == id })
        {
            return selected
        }
        if let appWindowDisplayID,
           let appWindowDisplay = displays.first(where: { $0.id == appWindowDisplayID })
        {
            return appWindowDisplay
        }
        return displays.first(where: \.isMain) ?? displays.first
    }
}
