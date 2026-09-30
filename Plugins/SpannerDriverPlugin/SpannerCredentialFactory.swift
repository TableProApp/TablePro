import Foundation
import TableProGoogleCloud
import TableProPluginKit
import TableProSpannerCore

internal struct SpannerConnectHTTPClient: GoogleHTTPClient {
    let base: any GoogleHTTPClient
    let phase: PluginConnectTimeoutPhase

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = phase.remainingSeconds(or: request.timeoutInterval)
        return try await base.send(request)
    }
}

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
            http = SpannerConnectHTTPClient(base: baseHTTP, phase: connectTimeoutPhase)
        } else {
            http = baseHTTP
        }
        switch settings.authMethod {
        case .emulator:
            return nil
        case .serviceAccount:
            let key = try GoogleServiceAccountKey.parse(
                fieldValue: try serviceAccountValue(fields: fields, password: config.password),
                readFile: { FileManager.default.contents(atPath: $0) }
            )
            return GoogleTokenProviders.serviceAccount(key, scopes: scopes, http: http)
        case .applicationDefault:
            let credentials = try GoogleApplicationDefaultCredentials.load(
                path: nil,
                readFile: { FileManager.default.contents(atPath: $0) },
                environment: ProcessInfo.processInfo.environment
            )
            return GoogleTokenProviders.applicationDefault(credentials, scopes: scopes, http: http)
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
