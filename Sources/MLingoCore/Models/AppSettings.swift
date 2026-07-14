import Foundation

public enum AppTheme: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var audioCaptureBackend: AudioCaptureBackend
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
        audioCaptureBackend: AudioCaptureBackend = .coreAudioTap,
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
        self.audioCaptureBackend = audioCaptureBackend
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

    private enum CodingKeys: String, CodingKey {
        case audioCaptureBackend
        case whisperModel
        case openAIModel
        case subtitleFontName
        case subtitleFontSize
        case subtitleBackgroundOpacity
        case subtitleTextOpacity
        case theme
        case sourceLanguage
        case targetLanguage
        case showBilingualSubtitles
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        audioCaptureBackend = try container.decodeIfPresent(
            AudioCaptureBackend.self,
            forKey: .audioCaptureBackend
        ) ?? .coreAudioTap
        whisperModel = try container.decode(String.self, forKey: .whisperModel)
        openAIModel = try container.decode(String.self, forKey: .openAIModel)
        subtitleFontName = try container.decode(String.self, forKey: .subtitleFontName)
        subtitleFontSize = try container.decode(Double.self, forKey: .subtitleFontSize)
        subtitleBackgroundOpacity = try container.decode(
            Double.self,
            forKey: .subtitleBackgroundOpacity
        )
        subtitleTextOpacity = try container.decode(Double.self, forKey: .subtitleTextOpacity)
        theme = try container.decode(AppTheme.self, forKey: .theme)
        sourceLanguage = try container.decode(String.self, forKey: .sourceLanguage)
        targetLanguage = try container.decode(String.self, forKey: .targetLanguage)
        showBilingualSubtitles = try container.decode(
            Bool.self,
            forKey: .showBilingualSubtitles
        )
    }
}
