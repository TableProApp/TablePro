import Foundation

public enum QdrantFieldID {
    public static let apiKey = "qdApiKey"
    public static let skipTLSVerify = "qdSkipTLSVerify"
}

public struct QdrantConnectionSettings: Sendable, Equatable {
    public static let defaultPort = 6_333

    public let host: String
    public let port: Int
    public let usesTLS: Bool
    public let apiKey: String
    public let skipTLSVerify: Bool

    public init(host: String, port: Int, usesTLS: Bool, apiKey: String, skipTLSVerify: Bool) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.usesTLS = usesTLS
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.skipTLSVerify = skipTLSVerify
    }

    public static func parse(
        host: String,
        port: Int,
        usesTLS: Bool,
        fields: [String: String]
    ) throws -> QdrantConnectionSettings {
        let resolvedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = QdrantConnectionSettings(
            host: resolvedHost.isEmpty ? "localhost" : resolvedHost,
            port: port > 0 ? port : defaultPort,
            usesTLS: usesTLS,
            apiKey: fields[QdrantFieldID.apiKey] ?? "",
            skipTLSVerify: fields[QdrantFieldID.skipTLSVerify] == "true"
        )
        _ = try settings.baseURL()
        return settings
    }

    /// Qdrant reads the key from `api-key`, and also accepts it as a bearer token; the dedicated
    /// header is the one both a self-hosted node and Qdrant Cloud document.
    public var headers: [String: String] {
        apiKey.isEmpty ? [:] : ["api-key": apiKey]
    }

    public func baseURL() throws -> URL {
        var components = URLComponents()
        components.scheme = usesTLS ? "https" : "http"
        components.host = host
        components.port = port
        guard let url = components.url else {
            throw QdrantError.configuration(String(localized: "The host is not valid in a URL."))
        }
        return url
    }
}
