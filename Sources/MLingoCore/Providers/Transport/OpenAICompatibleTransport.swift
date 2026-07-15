import Foundation

public protocol OpenAICompatibleTransporting: Sendable {
    func complete(
        _ request: OpenAICompatibleCompletionRequest,
        profile: ProviderProfile,
        secretProvider: @Sendable (CredentialID) throws -> String?
    ) async throws -> OpenAICompatibleCompletionResult
}

public final class OpenAICompatibleTransport: OpenAICompatibleTransporting,
    @unchecked Sendable
{
    public typealias RetryDelay = @Sendable (TimeInterval) async throws -> Void

    public static let defaultTimeout: TimeInterval = 8
    public static let defaultMaxRetryDelay: TimeInterval = 60

    private let httpClient: HTTPClientProtocol
    private let timeout: TimeInterval
    private let maxRetryDelay: TimeInterval
    private let retryDelay: RetryDelay

    public init(
        httpClient: HTTPClientProtocol = URLSession.shared,
        timeout: TimeInterval = OpenAICompatibleTransport.defaultTimeout,
        maxRetryDelay: TimeInterval = OpenAICompatibleTransport.defaultMaxRetryDelay,
        retryDelay: @escaping RetryDelay = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.httpClient = httpClient
        self.timeout = timeout
        self.maxRetryDelay = maxRetryDelay.isFinite && maxRetryDelay >= 0
            ? maxRetryDelay
            : OpenAICompatibleTransport.defaultMaxRetryDelay
        self.retryDelay = retryDelay
    }

    public func complete(
        _ request: OpenAICompatibleCompletionRequest,
        profile: ProviderProfile,
        secretProvider: @Sendable (CredentialID) throws -> String?
    ) async throws -> OpenAICompatibleCompletionResult {
        if let issue = profile.validationIssues.first {
            throw MLingoError.invalidTranslationConfiguration(issue.diagnosticMessage)
        }
        guard profile.apiStyle == .responses || profile.apiStyle == .chatCompletions else {
            throw MLingoError.invalidTranslationConfiguration(
                "Unsupported API style for OpenAI-compatible transport."
            )
        }

        var urlRequest = try OpenAICompatibleRequestBuilder.makeURLRequest(
            request: request,
            profile: profile,
            timeout: timeout
        )
        try OpenAICompatibleAuthApplicator.apply(
            authentication: profile.authentication,
            to: &urlRequest,
            secretProvider: secretProvider
        )

        let data = try await perform(urlRequest)
        return try OpenAICompatibleResponseParser.parse(data: data, style: profile.apiStyle)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        for attempt in 0...1 {
            do {
                let (data, response) = try await httpClient.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw MLingoError.invalidResponse
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    let mapped = OpenAICompatibleErrorMapper.mapHTTPError(
                        data: data,
                        statusCode: httpResponse.statusCode
                    )
                    logAPIError(mapped, response: httpResponse)
                    if attempt == 0, shouldRetry(mapped, statusCode: httpResponse.statusCode) {
                        try await retryDelay(retryDelaySeconds(from: httpResponse))
                        continue
                    }
                    throw mapped
                }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MLingoError {
                throw error
            } catch let error as URLError {
                throw OpenAICompatibleErrorMapper.mapURLError(error)
            } catch {
                throw MLingoError.translationFailed(error.localizedDescription)
            }
        }
        throw MLingoError.translationServiceUnavailable
    }

    private func shouldRetry(_ error: MLingoError, statusCode: Int) -> Bool {
        error == .rateLimited || (500..<600).contains(statusCode)
    }

    private func retryDelaySeconds(from response: HTTPURLResponse) -> TimeInterval {
        guard
            let value = response.value(forHTTPHeaderField: "Retry-After"),
            let seconds = TimeInterval(value),
            seconds.isFinite,
            seconds >= 0
        else {
            return 0.25
        }
        return min(seconds, maxRetryDelay)
    }

    private func logAPIError(_ error: MLingoError, response: HTTPURLResponse) {
        let requestID = ProviderDiagnosticRedactor.sanitizeServerControlledHeader(
            response.value(forHTTPHeaderField: "x-request-id")
        )
        // Status/code are public diagnostics; request ID is server-controlled → private.
        MLingoLogger.translation.error(
            "OpenAI-compatible request failed HTTP \(response.statusCode, privacy: .public), code \(error.diagnosticCode, privacy: .public), request ID \(requestID, privacy: .private)"
        )
    }
}

extension MLingoError {
    var diagnosticCode: String {
        switch self {
        case .missingAPIKey: "missing_api_key"
        case .invalidAPIKey: "invalid_api_key"
        case .invalidOpenAIModel: "invalid_model"
        case .quotaExceeded: "quota_exceeded"
        case .rateLimited: "rate_limited"
        case .networkOffline: "network_offline"
        case .requestTimedOut: "request_timed_out"
        case .translationServiceUnavailable: "service_unavailable"
        case .translationInputTooLong: "input_too_long"
        case .invalidTranslationConfiguration: "invalid_configuration"
        case .translationRequestRejected: "request_rejected"
        case .invalidResponse: "invalid_response"
        case .translationFailed: "translation_failed"
        default: "non_translation_error"
        }
    }
}

extension ProviderProfileValidationIssue {
    var diagnosticMessage: String {
        switch self {
        case .emptyName:
            "Provider profile name is empty."
        case .missingEndpoint:
            "Provider endpoint is missing."
        case .missingEndpointHost:
            "Provider endpoint host is missing."
        case .unsupportedEndpointScheme:
            "Provider endpoint scheme must be http or https."
        case .remoteEndpointRequiresHTTPS:
            "Remote endpoints require HTTPS. HTTP is only allowed for loopback."
        case .endpointContainsCredentials:
            "Provider endpoints must not include usernames or passwords. Store secrets in Keychain."
        case .endpointContainsQueryOrFragment:
            "Provider endpoints must not include query strings or fragments."
        case .invalidCustomHeaderName:
            "Custom authentication header name is invalid."
        case .emptyCredentialID:
            "Credential reference is empty."
        }
    }
}
