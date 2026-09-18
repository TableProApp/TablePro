import Foundation
import os

public struct GoogleOAuthTokens: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

extension GoogleOAuthTokens: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        let refresh = refreshToken == nil ? "nil" : "<redacted>"
        return "GoogleOAuthTokens(accessToken: <redacted>, refreshToken: \(refresh), expiresAt: \(expiresAt))"
    }

    public var debugDescription: String {
        description
    }
}

public struct GoogleOAuthLoopbackFlow: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "GoogleOAuthLoopbackFlow")

    private let client: GoogleOAuthClient
    private let scopes: [String]
    private let http: any GoogleHTTPClient
    private let timeout: Duration
    private let openURL: @Sendable (URL) async -> Bool

    public init(
        client: GoogleOAuthClient,
        scopes: [String],
        http: any GoogleHTTPClient,
        timeout: Duration = .seconds(120),
        openURL: @escaping @Sendable (URL) async -> Bool
    ) {
        self.client = client
        self.scopes = scopes
        self.http = http
        self.timeout = timeout
        self.openURL = openURL
    }

    public func run() async throws -> GoogleOAuthTokens {
        let pkce = GoogleOAuthPKCE.generate()
        let server = GoogleOAuthLoopbackServer(expectedState: pkce.state)
        defer { server.cancel() }
        let (outcome, redirectURI) = try await withTaskCancellationHandler {
            try await authorize(pkce: pkce, server: server)
        } onCancel: {
            server.cancel()
        }
        switch outcome {
        case .denied(let reason):
            Self.logger.notice("Google sign-in was denied in the browser")
            throw GoogleAuthError.oauthDenied(reason)
        case .code(let code):
            return try await exchange(code: code, verifier: pkce.verifier, redirectURI: redirectURI)
        }
    }

    func authorizationURL(pkce: GoogleOAuthPKCE, redirectURI: String) throws -> URL {
        let parameters: [(name: String, value: String)] = [
            (name: "client_id", value: client.clientId),
            (name: "redirect_uri", value: redirectURI),
            (name: "response_type", value: "code"),
            (name: "scope", value: effectiveScopes.joined(separator: " ")),
            (name: "code_challenge", value: pkce.challenge),
            (name: "code_challenge_method", value: "S256"),
            (name: "state", value: pkce.state),
            (name: "access_type", value: "offline"),
            (name: "prompt", value: "consent")
        ]
        var components = URLComponents(url: GoogleOAuthClient.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = GoogleTokenEndpoint.formEncoded(parameters)
        guard let url = components?.url else {
            throw GoogleAuthError.transport("invalidAuthorizationURL")
        }
        return url
    }

    private var effectiveScopes: [String] {
        let cleaned = scopes.map(GoogleCredentialDocument.trimmed).filter { !$0.isEmpty }
        return cleaned.isEmpty ? [GoogleOAuthClient.cloudPlatformScope] : cleaned
    }

    private func authorize(
        pkce: GoogleOAuthPKCE,
        server: GoogleOAuthLoopbackServer
    ) async throws -> (GoogleOAuthLoopbackOutcome, String) {
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"
        let url = try authorizationURL(pkce: pkce, redirectURI: redirectURI)
        guard await openURL(url) else {
            Self.logger.error("The browser could not be opened for Google sign-in")
            throw GoogleAuthError.oauthCancelled
        }
        let outcome = try await server.awaitOutcome(timeout: timeout)
        return (outcome, redirectURI)
    }

    private func exchange(code: String, verifier: String, redirectURI: String) async throws -> GoogleOAuthTokens {
        let request = GoogleTokenEndpoint.formRequest(
            url: GoogleOAuthClient.tokenEndpoint,
            fields: [
                (name: "code", value: code),
                (name: "client_id", value: client.clientId),
                (name: "client_secret", value: client.clientSecret),
                (name: "redirect_uri", value: redirectURI),
                (name: "grant_type", value: "authorization_code"),
                (name: "code_verifier", value: verifier)
            ]
        )
        do {
            let response = try await GoogleTokenEndpoint.requestToken(request, http: http, now: { Date() })
            if response.refreshToken == nil {
                Self.logger.warning("Google returned no refresh token for the sign-in")
            }
            return GoogleOAuthTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresAt: response.expiresAt
            )
        } catch is CancellationError {
            throw GoogleAuthError.oauthCancelled
        }
    }
}
