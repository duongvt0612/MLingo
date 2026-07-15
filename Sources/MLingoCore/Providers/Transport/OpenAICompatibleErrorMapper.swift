import Foundation

public enum OpenAICompatibleErrorMapper {
    public static func mapHTTPError(data: Data, statusCode: Int) -> MLingoError {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return fallbackError(statusCode: statusCode, message: nil)
        }
        return mapAPIError(from: dictionary, statusCode: statusCode)
    }

    public static func mapAPIError(
        from dictionary: [String: Any],
        statusCode: Int
    ) -> MLingoError {
        let payload = dictionary["error"] as? [String: Any]
            ?? ((dictionary["object"] as? String) == "error" ? dictionary : nil)
        let code = (payload?["code"] as? String)?.lowercased()
        let type = (payload?["type"] as? String)?.lowercased()
        let message = payload?["message"] as? String
        let identifiers = [code, type].compactMap { $0 }

        if statusCode == 401 || identifiers.contains(where: { $0.contains("invalid_api_key") }) {
            return .invalidAPIKey
        }
        if identifiers.contains(where: { $0.contains("model_not_found") }) {
            return .invalidOpenAIModel
        }
        if identifiers.contains(where: { $0.contains("quota") || $0.contains("billing") }) {
            return .quotaExceeded
        }
        if statusCode == 429 || identifiers.contains("rate_limit_exceeded") {
            return .rateLimited
        }
        return fallbackError(statusCode: statusCode, message: message)
    }

    public static func mapURLError(_ error: URLError) -> any Error {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
            return MLingoError.networkOffline
        case .timedOut:
            return MLingoError.requestTimedOut
        case .cancelled:
            return CancellationError()
        default:
            return MLingoError.translationFailed(error.localizedDescription)
        }
    }

    public static func fallbackError(statusCode: Int, message: String?) -> MLingoError {
        if (500..<600).contains(statusCode) {
            return .translationServiceUnavailable
        }
        let fallback = "The translation provider rejected the request (HTTP \(statusCode))."
        let resolvedMessage = message?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? fallback
        if (400..<500).contains(statusCode) {
            return .translationRequestRejected(resolvedMessage)
        }
        return .translationFailed(resolvedMessage)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
