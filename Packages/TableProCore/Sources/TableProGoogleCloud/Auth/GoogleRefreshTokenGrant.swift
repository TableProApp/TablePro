import Foundation

internal enum GoogleRefreshTokenGrant {
    static func request(client: GoogleOAuthClient, refreshToken: String) -> URLRequest {
        GoogleTokenEndpoint.formRequest(
            url: GoogleOAuthClient.tokenEndpoint,
            fields: [
                (name: "grant_type", value: "refresh_token"),
                (name: "client_id", value: client.clientId),
                (name: "client_secret", value: client.clientSecret),
                (name: "refresh_token", value: refreshToken)
            ]
        )
    }
}

internal struct GoogleAuthorizedUserTokenSource: GoogleAccessTokenSource {
    let client: GoogleOAuthClient
    let refreshToken: String
    let http: any GoogleHTTPClient
    let now: GoogleClock

    func fetchAccessToken() async throws -> GoogleAccessToken {
        let request = GoogleRefreshTokenGrant.request(client: client, refreshToken: refreshToken)
        let response = try await GoogleTokenEndpoint.requestToken(request, http: http, now: now)
        return GoogleAccessToken(value: response.accessToken, expiresAt: response.expiresAt)
    }
}

internal struct GoogleOAuthClientTokenSource: GoogleAccessTokenSource {
    private enum Origin {
        case pasted
        case stored
    }

    let client: GoogleOAuthClient
    let pastedRefreshToken: String?
    let store: any GoogleRefreshTokenStore
    let http: any GoogleHTTPClient
    let now: GoogleClock

    func fetchAccessToken() async throws -> GoogleAccessToken {
        let stored = storedRefreshToken()
        guard let pasted = pastedRefreshToken.map(GoogleCredentialDocument.trimmed), !pasted.isEmpty else {
            guard let stored else { throw GoogleAuthError.signInRequired }
            return try await exchange(stored, origin: .stored)
        }
        do {
            return try await exchange(pasted, origin: .pasted)
        } catch let error as GoogleAuthError where error.isAuthenticationFailure {
            guard let stored, stored != pasted else { throw error }
            return try await exchange(stored, origin: .stored)
        }
    }

    private func exchange(_ refreshToken: String, origin: Origin) async throws -> GoogleAccessToken {
        let request = GoogleRefreshTokenGrant.request(client: client, refreshToken: refreshToken)
        do {
            let response = try await GoogleTokenEndpoint.requestToken(request, http: http, now: now)
            if origin == .stored, let rotated = response.refreshToken, rotated != refreshToken {
                store.save(rotated, for: client.clientId)
            }
            return GoogleAccessToken(value: response.accessToken, expiresAt: response.expiresAt)
        } catch let error as GoogleAuthError where error.requiresSignIn {
            if origin == .stored, store.refreshToken(for: client.clientId) == refreshToken {
                store.removeRefreshToken(for: client.clientId)
            }
            throw error
        }
    }

    private func storedRefreshToken() -> String? {
        guard let stored = store.refreshToken(for: client.clientId), !stored.isEmpty else { return nil }
        return stored
    }
}
