import Foundation

public enum TranslationPromptBuilder {
    public static func instructions(settings: AppSettings) -> String {
        """
        Translate \(settings.sourceLanguage) subtitles into \(settings.targetLanguage).
        Requirements:
        - Natural \(settings.targetLanguage) suitable for on-screen subtitles.
        - Preserve names, product names, code terms, technical terms, and acronyms.
        - Do not summarize, explain, add commentary, or censor meaning.
        - Return only the translated subtitle text.
        """
    }

    public static func input(for transcript: Transcript) -> String {
        transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
