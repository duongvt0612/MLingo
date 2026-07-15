import Foundation

public enum TranslationResponseParser {
    public static func parse(data: Data) throws -> String {
        try OpenAICompatibleResponseParser.parse(data: data, style: .responses).text
    }

    static func apiError(data: Data, statusCode: Int) -> MLingoError {
        OpenAICompatibleErrorMapper.mapHTTPError(data: data, statusCode: statusCode)
    }
}
