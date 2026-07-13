import Foundation

public enum AppTheme: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var whisperModel: String
    public var openAIModel: String
    public var subtitleFontName: String
    public var subtitleFontSize: Double
    public var subtitleBackgroundOpacity: Double
    public var subtitleTextOpacity: Double
    public var theme: AppTheme
    public var sourceLanguage: String
    public var targetLanguage: String
    public var showBilingualSubtitles: Bool

    public init(
        whisperModel: String = "mlx-community/whisper-base-mlx",
        openAIModel: String = "gpt-4.1-mini",
        subtitleFontName: String = ".SFNS-Regular",
        subtitleFontSize: Double = 34,
        subtitleBackgroundOpacity: Double = 0.58,
        subtitleTextOpacity: Double = 1,
        theme: AppTheme = .system,
        sourceLanguage: String = "English",
        targetLanguage: String = "Vietnamese",
        showBilingualSubtitles: Bool = false
    ) {
        self.whisperModel = whisperModel
        self.openAIModel = openAIModel
        self.subtitleFontName = subtitleFontName
        self.subtitleFontSize = subtitleFontSize
        self.subtitleBackgroundOpacity = subtitleBackgroundOpacity
        self.subtitleTextOpacity = subtitleTextOpacity
        self.theme = theme
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.showBilingualSubtitles = showBilingualSubtitles
    }
}
