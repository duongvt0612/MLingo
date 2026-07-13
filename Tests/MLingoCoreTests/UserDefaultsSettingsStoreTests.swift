import Foundation
import Testing
@testable import MLingoCore

@Test
func settingsStoreRoundTripsSettings() async throws {
    let suiteName = "MLingoCoreTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = UserDefaultsSettingsStore(defaults: defaults, key: "settings")
    let expected = AppSettings(
        whisperModel: "whisper-test",
        openAIModel: "gpt-test",
        subtitleFontSize: 42,
        subtitleBackgroundOpacity: 0.7,
        theme: .dark,
        showBilingualSubtitles: true
    )

    try await store.save(expected)
    let actual = try await store.load()

    #expect(actual == expected)
}

@Test
func settingsStoreMigratesLegacyDefaultWhisperModel() async throws {
    let suiteName = "MLingoCoreTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let legacy = AppSettings(whisperModel: "mlx-community/whisper-small")
    defaults.set(try JSONEncoder().encode(legacy), forKey: "settings")

    let store = UserDefaultsSettingsStore(defaults: defaults, key: "settings")
    let migrated = try await store.load()

    #expect(migrated.whisperModel == "mlx-community/whisper-small-mlx")
}

@Test
func settingsStorePreservesCustomWhisperModel() async throws {
    let suiteName = "MLingoCoreTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let custom = AppSettings(whisperModel: "acme/custom-whisper")
    defaults.set(try JSONEncoder().encode(custom), forKey: "settings")

    let store = UserDefaultsSettingsStore(defaults: defaults, key: "settings")
    let loaded = try await store.load()

    #expect(loaded.whisperModel == custom.whisperModel)
}
