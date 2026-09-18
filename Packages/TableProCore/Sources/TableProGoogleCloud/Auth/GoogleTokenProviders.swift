import Foundation

public enum GoogleTokenProviders {
    public static func serviceAccount(
        _ key: GoogleServiceAccountKey,
        scopes: [String],
        http: any GoogleHTTPClient
    ) -> any GoogleAccessTokenProviding {
        serviceAccount(key, scopes: scopes, http: http, now: { Date() })
    }

    public static func applicationDefault(
        _ credentials: GoogleApplicationDefaultCredentials,
        scopes: [String],
        http: any GoogleHTTPClient
    ) -> any GoogleAccessTokenProviding {
        applicationDefault(credentials, scopes: scopes, http: http, now: { Date() })
    }

    public static func oauthClient(
        _ client: GoogleOAuthClient,
        pastedRefreshToken: String?,
        store: any GoogleRefreshTokenStore,
        http: any GoogleHTTPClient
    ) -> any GoogleAccessTokenProviding {
        oauthClient(client, pastedRefreshToken: pastedRefreshToken, store: store, http: http, now: { Date() })
    }

    static func serviceAccount(
        _ key: GoogleServiceAccountKey,
        scopes: [String],
        http: any GoogleHTTPClient,
        now: @escaping GoogleClock
    ) -> GoogleCachedAccessTokenProvider {
        let source = GoogleServiceAccountTokenSource(key: key, scopes: effectiveScopes(scopes), http: http, now: now)
        return GoogleCachedAccessTokenProvider(source: source, now: now)
    }

    static func applicationDefault(
        _ credentials: GoogleApplicationDefaultCredentials,
        scopes: [String],
        http: any GoogleHTTPClient,
        now: @escaping GoogleClock
    ) -> GoogleCachedAccessTokenProvider {
        switch credentials {
        case .serviceAccount(let key):
            return serviceAccount(key, scopes: scopes, http: http, now: now)
        case .authorizedUser(let clientId, let clientSecret, let refreshToken, _):
            let source = GoogleAuthorizedUserTokenSource(
                client: GoogleOAuthClient(clientId: clientId, clientSecret: clientSecret),
                refreshToken: refreshToken,
                http: http,
                now: now
            )
            return GoogleCachedAccessTokenProvider(source: source, now: now)
        case .impersonatedServiceAccount(let impersonationURL, let sourceCredentials, _, let delegates):
            let sourceProvider = applicationDefault(
                sourceCredentials,
                scopes: [GoogleOAuthClient.cloudPlatformScope],
                http: http,
                now: now
            )
            let source = GoogleImpersonatedTokenSource(
                impersonationURL: impersonationURL,
                sourceProvider: sourceProvider,
                scopes: effectiveScopes(scopes),
                delegates: delegates,
                http: http,
                now: now
            )
            return GoogleCachedAccessTokenProvider(source: source, now: now)
        }
    }

    static func oauthClient(
        _ client: GoogleOAuthClient,
        pastedRefreshToken: String?,
        store: any GoogleRefreshTokenStore,
        http: any GoogleHTTPClient,
        now: @escaping GoogleClock
    ) -> GoogleCachedAccessTokenProvider {
        let source = GoogleOAuthClientTokenSource(
            client: client,
            pastedRefreshToken: pastedRefreshToken,
            store: store,
            http: http,
            now: now
        )
        return GoogleCachedAccessTokenProvider(source: source, now: now)
    }

    private static func effectiveScopes(_ scopes: [String]) -> [String] {
        let cleaned = scopes.map(GoogleCredentialDocument.trimmed).filter { !$0.isEmpty }
        return cleaned.isEmpty ? [GoogleOAuthClient.cloudPlatformScope] : cleaned
    }
}
