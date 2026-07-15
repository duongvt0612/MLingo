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
        audioCaptureBackend: .screenCaptureKit,
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
func settingsStoreDefaultsLegacyDataToCoreAudioTap() async throws {
    let suiteName = "MLingoCoreTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let legacyJSON = """
    {
      "whisperModel": "mlx-community/whisper-base-mlx",
      "openAIModel": "gpt-4.1-mini",
      "subtitleFontName": ".SFNS-Regular",
      "subtitleFontSize": 34,
      "subtitleBackgroundOpacity": 0.58,
      "subtitleTextOpacity": 1,
      "theme": "system",
      "sourceLanguage": "English",
      "targetLanguage": "Vietnamese",
      "showBilingualSubtitles": false
    }
    """
    defaults.set(Data(legacyJSON.utf8), forKey: "settings")

    let store = UserDefaultsSettingsStore(defaults: defaults, key: "settings")
    let loaded = try await store.load()

    #expect(loaded.audioCaptureBackend == .coreAudioTap)
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

@Test
func settingsStoreRepairsMissingWrongTypeAndOutOfRangeFields() async throws {
    let suiteName = "MLingoCoreTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let legacyJSON = """
    {
      "audioCaptureBackend": 42,
      "whisperModel": "   ",
      "openAIModel": "  gpt-custom  ",
      "subtitleFontName": 99,
      "subtitleFontSize": 100,
      "subtitleBackgroundOpacity": -2,
      "subtitleTextOpacity": 2,
      "theme": "unknown",
      "sourceLanguage": [],
      "targetLanguage": "  Vietnamese  ",
      "showBilingualSubtitles": "yes"
    }
    """
    defaults.set(Data(legacyJSON.utf8), forKey: "settings")
    let store = UserDefaultsSettingsStore(defaults: defaults, key: "settings")

    let loaded = try await store.load()

    #expect(loaded.audioCaptureBackend == .coreAudioTap)
    #expect(loaded.whisperModel == AppSettings().whisperModel)
    #expect(loaded.openAIModel == "gpt-custom")
    #expect(loaded.subtitleFontName == AppSettings().subtitleFontName)
    #expect(loaded.subtitleFontSize == 64)
    #expect(loaded.subtitleBackgroundOpacity == 0.2)
    #expect(loaded.subtitleTextOpacity == 1)
    #expect(loaded.theme == .system)
    #expect(loaded.sourceLanguage == AppSettings().sourceLanguage)
    #expect(loaded.targetLanguage == "Vietnamese")
    #expect(!loaded.showBilingualSubtitles)

    let repairedData = try #require(defaults.data(forKey: "settings"))
    #expect(try JSONDecoder().decode(AppSettings.self, from: repairedData) == loaded)
}

@Test
func settingsStoreRemovesMalformedRootAndFallsBackToDefaults() async throws {
    let suiteName = "MLingoCoreTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(Data("not-json".utf8), forKey: "settings")
    let store = UserDefaultsSettingsStore(defaults: defaults, key: "settings")

    #expect(try await store.load() == AppSettings())
    #expect(defaults.data(forKey: "settings") == nil)
    #expect(try await store.load() == AppSettings())
}

@Test
func settingsStoreRejectsInvalidDraftWithoutWriting() async throws {
    let suiteName = "MLingoCoreTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsSettingsStore(defaults: defaults, key: "settings")

    await #expect(throws: MLingoError.invalidSettings("Enter an OpenAI model.")) {
        try await store.save(AppSettings(openAIModel: " "))
    }
    #expect(defaults.data(forKey: "settings") == nil)
}

@Test
func serializedSettingsNeverContainAnAPIKeyField() async throws {
    let suiteName = "MLingoCoreTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsSettingsStore(defaults: defaults, key: "settings")

    try await store.save(AppSettings())

    let data = try #require(defaults.data(forKey: "settings"))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["apiKey"] == nil)
}
