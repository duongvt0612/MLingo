import Testing
@testable import MLingoCore

@Test
func appSettingsValidationNormalizesStringsAndAcceptsRangeBoundaries() {
    let validation = AppSettingsValidation(
        settings: AppSettings(
            whisperModel: "  acme/whisper  ",
            openAIModel: "  gpt-test  ",
            subtitleFontName: "  .SFNS-Regular  ",
            subtitleFontSize: 18,
            subtitleBackgroundOpacity: 0.9,
            subtitleTextOpacity: 0,
            sourceLanguage: "  English  ",
            targetLanguage: "  Vietnamese  "
        )
    )

    #expect(validation.isValid)
    #expect(validation.errors.isEmpty)
    #expect(validation.normalizedSettings.whisperModel == "acme/whisper")
    #expect(validation.normalizedSettings.openAIModel == "gpt-test")
    #expect(validation.normalizedSettings.subtitleFontName == ".SFNS-Regular")
    #expect(validation.normalizedSettings.sourceLanguage == "English")
    #expect(validation.normalizedSettings.targetLanguage == "Vietnamese")
}

@Test
func appSettingsValidationReportsEveryFieldInDeterministicOrder() {
    let validation = AppSettingsValidation(
        settings: AppSettings(
            whisperModel: " ",
            openAIModel: "",
            subtitleFontName: "  ",
            subtitleFontSize: 17,
            subtitleBackgroundOpacity: 0.91,
            subtitleTextOpacity: -0.01,
            sourceLanguage: "",
            targetLanguage: " "
        )
    )

    #expect(!validation.isValid)
    #expect(Set(validation.errors.keys) == Set(AppSettingsField.allCases))
    #expect(validation.firstError == validation.errors[.whisperModel])
}

@Test(arguments: [18.0, 64.0])
func appSettingsValidationAcceptsFontSizeBoundaries(_ value: Double) {
    #expect(AppSettingsValidation(settings: AppSettings(subtitleFontSize: value)).isValid)
}

@Test(arguments: [0.2, 0.9])
func appSettingsValidationAcceptsBackgroundOpacityBoundaries(_ value: Double) {
    #expect(
        AppSettingsValidation(settings: AppSettings(subtitleBackgroundOpacity: value)).isValid
    )
}

@Test(arguments: [0.0, 1.0])
func appSettingsValidationAcceptsTextOpacityBoundaries(_ value: Double) {
    #expect(AppSettingsValidation(settings: AppSettings(subtitleTextOpacity: value)).isValid)
}
