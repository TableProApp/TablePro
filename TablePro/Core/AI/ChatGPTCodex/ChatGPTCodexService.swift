//
//  ChatGPTCodexService.swift
//  TablePro
//

import AppKit
import Foundation
import os

@MainActor @Observable
final class ChatGPTCodexService {
    static let shared = ChatGPTCodexService()

    private static let logger = Logger(subsystem: "com.TablePro", category: "ChatGPTCodexService")

    enum AuthState: Sendable, Equatable {
        case signedOut
        case signingIn
        case signedIn(email: String, planType: String?)

        var isSignedIn: Bool {
            if case .signedIn = self { return true }
            return false
        }
    }

    private(set) var authState: AuthState = .signedOut
    private(set) var errorMessage: String?

    @ObservationIgnored private let tokenStore: ChatGPTCodexTokenStore
    @ObservationIgnored private let oauthClient: ChatGPTCodexOAuthClient

    init(
        tokenStore: ChatGPTCodexTokenStore = .shared,
        oauthClient: ChatGPTCodexOAuthClient = ChatGPTCodexOAuthClient()
    ) {
        self.tokenStore = tokenStore
        self.oauthClient = oauthClient
    }

    func refreshAuthState() async {
        if let tokens = await tokenStore.currentTokens() {
            authState = .signedIn(email: tokens.email, planType: tokens.planType)
        } else {
            authState = .signedOut
        }
    }

    func signIn() async {
        errorMessage = nil
        authState = .signingIn

        let pkce = ChatGPTCodexPKCE()
        guard let authorizeURL = oauthClient.authorizeURL(pkce: pkce) else {
            failSignIn(AIProviderError.invalidEndpoint(ChatGPTCodex.authorizeEndpoint))
            return
        }

        let server = ChatGPTCodexCallbackServer(expectedState: pkce.state)
        do {
            try await server.start()
            NSWorkspace.shared.open(authorizeURL)
            let code = try await server.waitForCode()
            let response = try await oauthClient.exchangeCode(code: code, verifier: pkce.verifier)
            let claims = try ChatGPTCodexJWT.decodeClaims(from: response.idToken)
            let tokens = ChatGPTCodexTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                idToken: response.idToken,
                accountID: claims.accountID,
                email: claims.email,
                planType: claims.planType,
                expiresAt: response.expiresAt
            )
            await tokenStore.save(tokens)
            authState = .signedIn(email: claims.email, planType: claims.planType)
            Self.logger.info("ChatGPT sign-in succeeded")
        } catch {
            server.stop()
            failSignIn(error)
        }
    }

    func importFromCodexCLI() async {
        errorMessage = nil
        do {
            let tokens = try ChatGPTCodexCLIImporter.loadTokens()
            await tokenStore.save(tokens)
            authState = .signedIn(email: tokens.email, planType: tokens.planType)
            Self.logger.info("Imported ChatGPT session from Codex CLI")
        } catch {
            errorMessage = error.localizedDescription
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
        Self.logger.error("ChatGPT sign-in failed: \(error.localizedDescription, privacy: .public)")
        errorMessage = error.localizedDescription
        authState = .signedOut
    }
}
