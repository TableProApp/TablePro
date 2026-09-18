import Foundation

public enum WeaviateFieldID {
    public static let authMethod = "wvAuthMethod"
    public static let apiKey = "wvApiKey"
    public static let skipTLSVerify = "wvSkipTLSVerify"
}

public enum WeaviateAuthMethod: String, Sendable, Equatable {
    case none
    case apiKey
}

public struct WeaviateAuth: Sendable, Equatable {
    public let method: WeaviateAuthMethod
    public let apiKey: String

    public init(method: WeaviateAuthMethod, apiKey: String = "") {
        self.method = method
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func parse(fields: [String: String]) -> WeaviateAuth {
        let raw = fields[WeaviateFieldID.authMethod] ?? WeaviateAuthMethod.none.rawValue
        let method = WeaviateAuthMethod(rawValue: raw) ?? .none
        return WeaviateAuth(method: method, apiKey: fields[WeaviateFieldID.apiKey] ?? "")
    }

    /// A key left in the form after the user switches back to None must not be sent: the form
    /// keeps the field's text, and only the method says whether the connection is authenticated.
    public var authorizationHeader: String? {
        guard method == .apiKey, !apiKey.isEmpty else { return nil }
        return "Bearer \(apiKey)"
    }
}

public struct WeaviateConnectionSettings: Sendable, Equatable {
    public static let defaultPort = 8_080

    public let host: String
    public let port: Int
    public let usesTLS: Bool
    public let auth: WeaviateAuth
    public let skipTLSVerify: Bool

    public init(
        host: String,
        port: Int,
        usesTLS: Bool,
        auth: WeaviateAuth,
        skipTLSVerify: Bool
    ) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.usesTLS = usesTLS
        self.auth = auth
        self.skipTLSVerify = skipTLSVerify
    }

    public static func parse(
        host: String,
        port: Int,
        usesTLS: Bool,
        fields: [String: String]
    ) throws -> WeaviateConnectionSettings {
        let resolvedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPort = port > 0 ? port : defaultPort
        let skipTLS = fields[WeaviateFieldID.skipTLSVerify] == "true"
        let settings = WeaviateConnectionSettings(
            host: resolvedHost.isEmpty ? "localhost" : resolvedHost,
            port: resolvedPort,
            usesTLS: usesTLS,
            auth: WeaviateAuth.parse(fields: fields),
            skipTLSVerify: skipTLS
        )
        _ = try settings.baseURL()
        if settings.auth.method == .apiKey, settings.auth.apiKey.isEmpty {
            throw WeaviateError.configuration(String(localized: "Enter a Weaviate API key."))
        }
        return settings
    }

    public func baseURL() throws -> URL {
        var components = URLComponents()
        components.scheme = usesTLS ? "https" : "http"
        components.host = host
        components.port = port
        guard let url = components.url else {
            throw WeaviateError.configuration(String(localized: "The host is not valid in a URL."))
        }
        return url
    }
}
