import Foundation
import TableProGoogleCloud
import TableProPluginKit
import TableProSpannerCore

internal enum SpannerCredentialFactory {
    static let scopes = [GoogleOAuthClient.cloudPlatformScope]

    static func tokenProvider(
        settings: SpannerConnectionSettings,
        config: DriverConnectionConfig,
        connectTimeoutPhase: PluginConnectTimeoutPhase? = nil
    ) throws -> (any GoogleAccessTokenProviding)? {
        let fields = config.additionalFields
        let baseHTTP = URLSessionGoogleHTTPClient()
        let http: any GoogleHTTPClient
        if let connectTimeoutPhase {
            http = GoogleDeadlineHTTPClient(base: baseHTTP) { connectTimeoutPhase.remainingSeconds(or: $0) }
        } else {
            http = baseHTTP
        }
        switch settings.authMethod {
        case .emulator:
            return nil
        case .serviceAccount:
            return try credentials(
                from: .serviceAccountKey(try serviceAccountValue(fields: fields, password: config.password)),
                http: http
            )
        case .applicationDefault:
            return try credentials(from: .applicationDefault, http: http)
        case .oauth:
            let client = GoogleOAuthClient(
                clientId: try required("spOAuthClientId", in: fields),
                clientSecret: try required("spOAuthClientSecret", in: fields)
            )
            return GoogleTokenProviders.oauthClient(
                client,
                pastedRefreshToken: trimmed(fields["spOAuthRefreshToken"]),
                store: GoogleKeychainRefreshTokenStore(),
                http: http
            )
        }
    }

    private static func credentials(
        from source: GoogleCredentialSource,
        http: any GoogleHTTPClient
    ) throws -> any GoogleAccessTokenProviding {
        try GoogleTokenProviders.credentials(
            from: source,
            scopes: scopes,
            readFile: { FileManager.default.contents(atPath: $0) },
            environment: ProcessInfo.processInfo.environment,
            http: http
        ).tokenProvider
    }

    private static func serviceAccountValue(fields: [String: String], password: String) throws -> String {
        if let value = trimmed(fields["spServiceAccountJson"]) {
            return value
        }
        if let value = trimmed(password) {
            return value
        }
        throw SpannerConfigurationError.missingField("spServiceAccountJson")
    }

    private static func required(_ key: String, in fields: [String: String]) throws -> String {
        guard let value = trimmed(fields[key]) else {
            throw SpannerConfigurationError.missingField(key)
        }
        return value
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
