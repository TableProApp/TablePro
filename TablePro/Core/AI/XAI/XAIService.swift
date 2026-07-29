//
//  XAIService.swift
//  TablePro
//

import AppKit
import Foundation
import os

@MainActor @Observable
final class XAIService {
    static let shared = XAIService()

    private static let logger = Logger(subsystem: "com.TablePro", category: "XAIService")

    enum AuthState: Sendable, Equatable {
        case signedOut
        case signingIn
        case signedIn(email: String)

        var isSignedIn: Bool {
            if case .signedIn = self { return true }
            return false
        }
    }

    private(set) var authState: AuthState = .signedOut
    private(set) var errorMessage: String?

    @ObservationIgnored private let tokenStore: XAITokenStore
    @ObservationIgnored private let oauthClient: XAIOAuthClient

    init(
        tokenStore: XAITokenStore = .shared,
        oauthClient: XAIOAuthClient = XAIOAuthClient()
    ) {
        self.tokenStore = tokenStore
        self.oauthClient = oauthClient
    }

    func refreshAuthState() async {
        if let tokens = await tokenStore.currentTokens() {
            authState = .signedIn(email: tokens.email)
        } else {
            authState = .signedOut
        }
    }

    func signIn() async {
        errorMessage = nil
        authState = .signingIn

        let pkce = XAIPKCE()
        let server = XAICallbackServer(expectedState: pkce.state)
        do {
            try await server.start()
            let redirectURI = server.redirectURI
            guard let authorizeURL = oauthClient.authorizeURL(pkce: pkce, redirectURI: redirectURI) else {
                server.stop()
                failSignIn(AIProviderError.invalidEndpoint(XAI.authorizeEndpoint))
                return
            }
            NSWorkspace.shared.open(authorizeURL)
            let code = try await server.waitForCode()
            let response = try await oauthClient.exchangeCode(
                code: code,
                verifier: pkce.verifier,
                redirectURI: redirectURI
            )
            let email = XAIIdentity.email(fromIDToken: response.idToken)
            let tokens = XAITokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                idToken: response.idToken,
                email: email,
                expiresAt: response.expiresAt
            )
            await tokenStore.save(tokens)
            authState = .signedIn(email: email)
            Self.logger.info("xAI sign-in succeeded")
        } catch {
            server.stop()
            failSignIn(error)
        }
    }

    func signOut() async {
        if let tokens = await tokenStore.currentTokens() {
            await oauthClient.revoke(refreshToken: tokens.refreshToken)
        }
        await tokenStore.clear()
        authState = .signedOut
        errorMessage = nil
    }

    private func failSignIn(_ error: Error) {
        Self.logger.error("xAI sign-in failed: \(error.localizedDescription, privacy: .public)")
        errorMessage = error.localizedDescription
        authState = .signedOut
    }
}
