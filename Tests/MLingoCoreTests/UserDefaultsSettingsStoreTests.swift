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
