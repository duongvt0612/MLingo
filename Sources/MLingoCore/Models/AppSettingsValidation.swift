import Foundation

public enum AppSettingsField: String, CaseIterable, Hashable, Sendable {
    case whisperModel
    case openAIModel
    case subtitleFontName
    case subtitleFontSize
    case subtitleBackgroundOpacity
    case subtitleTextOpacity
    case sourceLanguage
    case targetLanguage
}

public struct AppSettingsValidation: Equatable, Sendable {
    public let normalizedSettings: AppSettings
    public let errors: [AppSettingsField: String]

    public init(settings: AppSettings) {
        var normalized = settings
        normalized.whisperModel = settings.whisperModel.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        normalized.openAIModel = settings.openAIModel.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        normalized.subtitleFontName = settings.subtitleFontName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        normalized.sourceLanguage = settings.sourceLanguage.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        normalized.targetLanguage = settings.targetLanguage.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        normalizedSettings = normalized

        var errors: [AppSettingsField: String] = [:]
        if normalized.whisperModel.isEmpty {
            errors[.whisperModel] = "Enter a Whisper model."
        }
        if normalized.openAIModel.isEmpty {
            errors[.openAIModel] = "Enter an OpenAI model."
        }
        if normalized.subtitleFontName.isEmpty {
            errors[.subtitleFontName] = "Enter a subtitle font name."
        }
        if !(18...64).contains(normalized.subtitleFontSize) {
            errors[.subtitleFontSize] = "Choose a subtitle font size from 18 to 64 pt."
        }
        if !(0.2...0.9).contains(normalized.subtitleBackgroundOpacity) {
            errors[.subtitleBackgroundOpacity] = "Choose a background opacity from 20% to 90%."
        }
        if !(0...1).contains(normalized.subtitleTextOpacity) {
            errors[.subtitleTextOpacity] = "Choose a text opacity from 0% to 100%."
        }
        if normalized.sourceLanguage.isEmpty {
            errors[.sourceLanguage] = "Enter a source language."
        }
        if normalized.targetLanguage.isEmpty {
            errors[.targetLanguage] = "Enter a target language."
        }
        self.errors = errors
    }

    public var isValid: Bool { errors.isEmpty }

    public var firstError: String? {
        AppSettingsField.allCases.lazy.compactMap { errors[$0] }.first
    }
}
