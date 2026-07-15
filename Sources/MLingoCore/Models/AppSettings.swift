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
        openAIModel: String = "gpt-5.4-mini",
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
        let defaults = AppSettings()

        func decode<T: Decodable>(
            _ type: T.Type,
            forKey key: CodingKeys,
            default defaultValue: T
        ) -> T {
            do {
                return try container.decodeIfPresent(type, forKey: key) ?? defaultValue
            } catch {
                return defaultValue
            }
        }

        func repairedString(forKey key: CodingKeys, default defaultValue: String) -> String {
            let value = decode(String.self, forKey: key, default: defaultValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? defaultValue : value
        }

        func clamped(
            _ value: Double,
            to range: ClosedRange<Double>,
            default defaultValue: Double
        ) -> Double {
            guard value.isFinite else { return defaultValue }
            return min(max(value, range.lowerBound), range.upperBound)
        }

        audioCaptureBackend = decode(
            AudioCaptureBackend.self,
            forKey: .audioCaptureBackend,
            default: defaults.audioCaptureBackend
        )
        whisperModel = repairedString(
            forKey: .whisperModel,
            default: defaults.whisperModel
        )
        openAIModel = repairedString(forKey: .openAIModel, default: defaults.openAIModel)
        subtitleFontName = repairedString(
            forKey: .subtitleFontName,
            default: defaults.subtitleFontName
        )
        subtitleFontSize = clamped(
            decode(
                Double.self,
                forKey: .subtitleFontSize,
                default: defaults.subtitleFontSize
            ),
            to: 18...64,
            default: defaults.subtitleFontSize
        )
        subtitleBackgroundOpacity = clamped(
            decode(
                Double.self,
                forKey: .subtitleBackgroundOpacity,
                default: defaults.subtitleBackgroundOpacity
            ),
            to: 0.2...0.9,
            default: defaults.subtitleBackgroundOpacity
        )
        subtitleTextOpacity = clamped(
            decode(
                Double.self,
                forKey: .subtitleTextOpacity,
                default: defaults.subtitleTextOpacity
            ),
            to: 0...1,
            default: defaults.subtitleTextOpacity
        )
        theme = decode(AppTheme.self, forKey: .theme, default: defaults.theme)
        sourceLanguage = repairedString(
            forKey: .sourceLanguage,
            default: defaults.sourceLanguage
        )
        targetLanguage = repairedString(
            forKey: .targetLanguage,
            default: defaults.targetLanguage
        )
        showBilingualSubtitles = decode(
            Bool.self,
            forKey: .showBilingualSubtitles,
            default: defaults.showBilingualSubtitles
        )
    }
}
