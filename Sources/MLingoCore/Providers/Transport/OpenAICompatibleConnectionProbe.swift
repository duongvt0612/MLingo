import Foundation

public struct ProviderConnectionTestResult: Sendable, Equatable {
    public var succeeded: Bool
    public var message: String
    public var models: [String]

    public init(succeeded: Bool, message: String, models: [String] = []) {
        self.succeeded = succeeded
        self.message = message
        self.models = models
    }
}

public struct OpenAICompatibleModelDiscoveryResult: Sendable, Equatable {
    public var models: [String]
    public var modelsEndpointAvailable: Bool

    public init(models: [String], modelsEndpointAvailable: Bool) {
        self.models = models
        self.modelsEndpointAvailable = modelsEndpointAvailable
    }
}

public protocol ProviderConnectionProbing: Sendable {
    func testConnection(
        profile: ProviderProfile,
        secretProvider: @Sendable (CredentialID) throws -> String?
    ) async throws -> ProviderConnectionTestResult
}

public final class OpenAICompatibleConnectionProbe: ProviderConnectionProbing,
    @unchecked Sendable
{
    private let httpClient: HTTPClientProtocol
    private let timeout: TimeInterval
    private let retryDelay: OpenAICompatibleTransport.RetryDelay

    public init(
        httpClient: HTTPClientProtocol = URLSession.shared,
        timeout: TimeInterval = 5,
        retryDelay: @escaping OpenAICompatibleTransport.RetryDelay = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.httpClient = httpClient
        self.timeout = timeout
        self.retryDelay = retryDelay
    }

    public func testConnection(
        profile: ProviderProfile,
        secretProvider: @Sendable (CredentialID) throws -> String?
    ) async throws -> ProviderConnectionTestResult {
        if let issue = profile.validationIssues.first {
            throw MLingoError.invalidTranslationConfiguration(issue.diagnosticMessage)
        }
        guard profile.endpoint != nil else {
            throw MLingoError.invalidTranslationConfiguration("Provider endpoint is missing.")
        }

        do {
            let discovery = try await listModels(
                profile: profile,
                secretProvider: secretProvider
            )
            if discovery.modelsEndpointAvailable {
                return ProviderConnectionTestResult(
                    succeeded: true,
                    message: discovery.models.isEmpty
                        ? "Connected. Model list is empty."
                        : "Connected. Discovered \(discovery.models.count) model(s).",
                    models: discovery.models
                )
            }
        } catch let error as MLingoError where error == .invalidOpenAIModel {
            // Models endpoint missing — fall through to minimal completion probe.
        } catch {
            throw error
        }

        // Fallback: tiny completion when /models is unavailable.
        let transport = OpenAICompatibleTransport(
            httpClient: httpClient,
            timeout: timeout,
            retryDelay: retryDelay
        )
        let model = profile.models[.translation]?.first
            ?? profile.models.values.flatMap { $0 }.first
            ?? "test"
        _ = try await transport.complete(
            OpenAICompatibleCompletionRequest(
                model: model,
                instructions: "Reply with OK.",
                input: "ping",
                maxOutputTokens: 1
            ),
            profile: profile,
            secretProvider: secretProvider
        )
        return ProviderConnectionTestResult(
            succeeded: true,
            message: "Connected via completion probe.",
            models: []
        )
    }

    public func listModels(
        profile: ProviderProfile,
        secretProvider: @Sendable (CredentialID) throws -> String?
    ) async throws -> OpenAICompatibleModelDiscoveryResult {
        if let issue = profile.validationIssues.first {
            throw MLingoError.invalidTranslationConfiguration(issue.diagnosticMessage)
        }
        guard let endpoint = profile.endpoint else {
            throw MLingoError.invalidTranslationConfiguration("Provider endpoint is missing.")
        }

        let url = OpenAICompatibleRequestBuilder.modelsURL(base: endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        try OpenAICompatibleAuthApplicator.apply(
            authentication: profile.authentication,
            to: &request,
            secretProvider: secretProvider
        )

        do {
            let (data, response) = try await httpClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MLingoError.invalidResponse
            }
            if [404, 405, 501].contains(httpResponse.statusCode) {
                return OpenAICompatibleModelDiscoveryResult(
                    models: [],
                    modelsEndpointAvailable: false
                )
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw OpenAICompatibleErrorMapper.mapHTTPError(
                    data: data,
                    statusCode: httpResponse.statusCode
                )
            }
            let models = try parseModelIDs(from: data)
            return OpenAICompatibleModelDiscoveryResult(
                models: models,
                modelsEndpointAvailable: true
            )
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

    private func parseModelIDs(from data: Data) throws -> [String] {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = object["data"] as? [[String: Any]]
        else {
            throw MLingoError.invalidResponse
        }
        return list.compactMap { item in
            (item["id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
