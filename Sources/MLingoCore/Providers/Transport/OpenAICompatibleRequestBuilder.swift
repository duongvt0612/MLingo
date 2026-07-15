import Foundation

public struct OpenAICompatibleCompletionRequest: Sendable, Equatable {
    public var model: String
    public var instructions: String
    public var input: String
    public var maxOutputTokens: Int

    public init(
        model: String,
        instructions: String,
        input: String,
        maxOutputTokens: Int
    ) {
        self.model = model
        self.instructions = instructions
        self.input = input
        self.maxOutputTokens = maxOutputTokens
    }
}

public enum OpenAICompatibleRequestBuilder {
    public static func makeURLRequest(
        request: OpenAICompatibleCompletionRequest,
        profile: ProviderProfile,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let endpoint = profile.endpoint else {
            throw MLingoError.invalidTranslationConfiguration("Provider endpoint is missing.")
        }
        let url = try completionURL(base: endpoint, style: profile.apiStyle)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: body(request: request, style: profile.apiStyle)
        )
        return urlRequest
    }

    public static func completionURL(base: URL, style: ProviderAPIStyle) throws -> URL {
        switch style {
        case .responses:
            return join(base: base, pathComponent: "responses")
        case .chatCompletions:
            return join(base: base, pathComponent: "chat/completions")
        case .native:
            throw MLingoError.invalidTranslationConfiguration(
                "Native API style is not supported by the OpenAI-compatible transport."
            )
        }
    }

    public static func body(
        request: OpenAICompatibleCompletionRequest,
        style: ProviderAPIStyle
    ) throws -> [String: Any] {
        switch style {
        case .responses:
            return [
                "model": request.model,
                "instructions": request.instructions,
                "input": request.input,
                "store": false,
                "max_output_tokens": request.maxOutputTokens,
            ]
        case .chatCompletions:
            return [
                "model": request.model,
                "messages": [
                    ["role": "system", "content": request.instructions],
                    ["role": "user", "content": request.input],
                ],
                "max_tokens": request.maxOutputTokens,
                "stream": false,
            ]
        case .native:
            throw MLingoError.invalidTranslationConfiguration(
                "Native API style is not supported by the OpenAI-compatible transport."
            )
        }
    }

    public static func modelsURL(base: URL) -> URL {
        join(base: base, pathComponent: "models")
    }

    private static func join(base: URL, pathComponent: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        // Profiles reject query/fragment; clear them if a caller bypasses validation.
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil

        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        let component = pathComponent.hasPrefix("/")
            ? String(pathComponent.dropFirst())
            : pathComponent
        components.path = path.isEmpty ? "/\(component)" : "\(path)/\(component)"
        return components.url ?? base.appendingPathComponent(component)
    }
}
