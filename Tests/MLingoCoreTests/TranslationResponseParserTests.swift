import Foundation
import Testing
@testable import MLingoCore

@Test
func parserReadsConvenienceOutputText() throws {
    let data = #"{"output_text":"Xin chao"}"#.data(using: .utf8)!
    #expect(try TranslationResponseParser.parse(data: data) == "Xin chao")
}

@Test
func parserReadsResponsesOutputContent() throws {
    let data = """
    {
      "output": [
        {
          "content": [
            { "type": "output_text", "text": "Xin " },
            { "type": "output_text", "text": "chao" }
          ]
        }
      ]
    }
    """.data(using: .utf8)!

    #expect(try TranslationResponseParser.parse(data: data) == "Xin chao")
}

@Test
func promptPreservesTranslationRules() {
    let settings = AppSettings(sourceLanguage: "English", targetLanguage: "Vietnamese")
    let instructions = TranslationPromptBuilder.instructions(settings: settings)

    #expect(instructions.contains("Preserve names"))
    #expect(instructions.contains("Do not summarize"))
    #expect(instructions.contains("Return only"))
}
