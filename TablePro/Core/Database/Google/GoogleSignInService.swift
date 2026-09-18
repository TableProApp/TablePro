import AppKit
import Foundation
import os
import TableProGoogleCloud
import TableProPluginKit

internal enum GoogleSignInService {
    static let invalidAuthorizationSQLState = "28000"

    private static let logger = Logger(subsystem: "com.TablePro", category: "GoogleSignInService")

    static func claims(_ error: Error, fields: [String: String]) -> Bool {
        guard GoogleOAuthConnectionFields.active(in: fields) != nil else { return false }
        return needsSignIn(error)
    }

    static func needsSignIn(_ error: Error) -> Bool {
        guard let driverError = error as? any PluginDriverError else { return false }
        return driverError.pluginSqlState == invalidAuthorizationSQLState
    }

    static func client(from fields: [String: String]) throws -> GoogleOAuthClient {
        guard let connectionFields = GoogleOAuthConnectionFields.active(in: fields),
              let client = connectionFields.client(from: fields)
        else {
            throw GoogleSignInError.clientNotConfigured
        }
        return client
    }

    @MainActor
    static func signIn(fields: [String: String]) async throws {
        let client = try client(from: fields)
        let flow = GoogleOAuthLoopbackFlow(
            client: client,
            scopes: [GoogleOAuthClient.cloudPlatformScope],
            http: URLSessionGoogleHTTPClient(),
            openURL: { url in
                await MainActor.run { NSWorkspace.shared.open(url) }
            }
        )
        let tokens: GoogleOAuthTokens
        do {
            tokens = try await flow.run()
        } catch let error as GoogleAuthError {
            logger.error("Google sign-in failed: \(String(describing: error), privacy: .private)")
            throw GoogleSignInError.authentication(error)
        } catch is CancellationError {
            throw GoogleSignInError.authentication(.oauthCancelled)
        }
        try storeRefreshToken(from: tokens, for: client, in: GoogleKeychainRefreshTokenStore())
    }

    static func storeRefreshToken(
        from tokens: GoogleOAuthTokens,
        for client: GoogleOAuthClient,
        in store: any GoogleRefreshTokenStore
    ) throws {
        guard let refreshToken = tokens.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty
        else {
            logger.error("Google sign-in finished without a refresh token")
            throw GoogleSignInError.noRefreshToken
        }
        store.save(refreshToken, for: client.clientId)
        logger.info("Stored the refresh token from Google sign-in")
    }
}
