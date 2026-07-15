import Foundation

public final class UserDefaultsSettingsStore: SettingsStoreProtocol, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        key: String = "com.duongvt.MLingo.settings"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() async throws -> AppSettings {
        lock.withLock {
            guard let data = defaults.data(forKey: key) else {
                return AppSettings()
            }

            do {
                var settings = try decoder.decode(AppSettings.self, from: data)
                if settings.whisperModel == "mlx-community/whisper-small" {
                    settings.whisperModel = "mlx-community/whisper-small-mlx"
                }
                let normalized = AppSettingsValidation(settings: settings).normalizedSettings
                defaults.set(try encoder.encode(normalized), forKey: key)
                return normalized
            } catch {
                defaults.removeObject(forKey: key)
                MLingoLogger.settings.warning("Discarded malformed persisted settings")
                return AppSettings()
            }
        }
    }

    public func save(_ settings: AppSettings) async throws {
        try lock.withLock {
            let validation = AppSettingsValidation(settings: settings)
            guard validation.isValid else {
                throw MLingoError.invalidSettings(
                    validation.firstError ?? "Review the settings and try again."
                )
            }
            let data = try encoder.encode(validation.normalizedSettings)
            defaults.set(data, forKey: key)
        }
    }
}
