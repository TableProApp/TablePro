//
//  ChatGPTCodexTokenStore.swift
//  TablePro
//

import Foundation
import os

actor ChatGPTCodexTokenStore {
    static let shared = ChatGPTCodexTokenStore()

    private static let logger = Logger(subsystem: "com.TablePro", category: "ChatGPTCodexTokenStore")
    private static let storageKey = "com.TablePro.aioauth.chatgptCodex"

    private let keychain: KeychainStoring
    private let refresher: ChatGPTCodexTokenRefreshing
    private var cached: ChatGPTCodexTokens?
    private var refreshTask: Task<ChatGPTCodexTokens, Error>?

    init(
        keychain: KeychainStoring = KeychainHelper.shared,
        refresher: ChatGPTCodexTokenRefreshing = ChatGPTCodexOAuthClient()
    ) {
        self.keychain = keychain
        self.refresher = refresher
    }

    func currentTokens() -> ChatGPTCodexTokens? {
        loadTokens()
    }

    func accountID() -> String? {
        loadTokens()?.accountID
    }

    func isSignedIn() -> Bool {
        loadTokens() != nil
    }

    func save(_ tokens: ChatGPTCodexTokens) {
        persist(tokens)
    }

    func clear() {
        cached = nil
        refreshTask?.cancel()
        refreshTask = nil
        keychain.delete(forKey: Self.storageKey)
    }

    func validAccessToken() async throws -> String {
        guard let tokens = loadTokens() else {
            throw AIProviderError.authenticationFailed(String(localized: "Not signed in to ChatGPT."))
        }
        if !tokens.isExpired {
            return tokens.accessToken
        }
        return try await refresh(using: tokens.refreshToken).accessToken
    }

    func forceRefresh() async throws -> String {
        guard let tokens = loadTokens() else {
            throw AIProviderError.authenticationFailed(String(localized: "Not signed in to ChatGPT."))
        }
        return try await refresh(using: tokens.refreshToken).accessToken
    }

    private func refresh(using refreshToken: String) async throws -> ChatGPTCodexTokens {
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task<ChatGPTCodexTokens, Error> {
            let response = try await refresher.refresh(refreshToken: refreshToken)
            return persistRefreshed(response)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch {
            if case AIProviderError.authenticationFailed = error {
                Self.logger.notice("ChatGPT refresh rejected; clearing stored session")
                clear()
            }
            throw error
        }
    }

    private func persistRefreshed(_ response: ChatGPTCodexTokenResponse) -> ChatGPTCodexTokens {
        let previous = loadTokens()
        let claims = response.idToken.isEmpty ? nil : try? ChatGPTCodexJWT.decodeClaims(from: response.idToken)
        let tokens = ChatGPTCodexTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken.isEmpty ? (previous?.refreshToken ?? "") : response.refreshToken,
            idToken: response.idToken.isEmpty ? (previous?.idToken ?? "") : response.idToken,
            accountID: claims?.accountID ?? previous?.accountID ?? "",
            email: claims?.email ?? previous?.email ?? "",
            planType: claims?.planType ?? previous?.planType,
            expiresAt: response.expiresAt
        )
        persist(tokens)
        return tokens
    }

    private func persist(_ tokens: ChatGPTCodexTokens) {
        cached = tokens
        guard let data = try? JSONEncoder().encode(tokens),
              let json = String(data: data, encoding: .utf8) else {
            Self.logger.error("Failed to encode ChatGPT tokens for Keychain")
            return
        }
        keychain.writeString(json, forKey: Self.storageKey)
    }

    private func loadTokens() -> ChatGPTCodexTokens? {
        if let cached {
            return cached
        }
        guard case .found(let json) = keychain.readStringResult(forKey: Self.storageKey),
              let data = json.data(using: .utf8),
              let tokens = try? JSONDecoder().decode(ChatGPTCodexTokens.self, from: data) else {
            return nil
        }
        cached = tokens
        return tokens
    }
}
