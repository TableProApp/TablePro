//
//  XAITokenStore.swift
//  TablePro
//

import Foundation
import os

actor XAITokenStore {
    static let shared = XAITokenStore()

    private static let logger = Logger(subsystem: "com.TablePro", category: "XAITokenStore")
    private static let storageKey = "com.TablePro.aioauth.xai"

    private let keychain: KeychainStoring
    private let refresher: XAITokenRefreshing
    private var cached: XAITokens?
    private var refreshTask: Task<XAITokens, Error>?

    init(
        keychain: KeychainStoring = KeychainHelper.shared,
        refresher: XAITokenRefreshing = XAIOAuthClient()
    ) {
        self.keychain = keychain
        self.refresher = refresher
    }

    func currentTokens() -> XAITokens? {
        loadTokens()
    }

    func email() -> String? {
        loadTokens()?.email
    }

    func isSignedIn() -> Bool {
        loadTokens() != nil
    }

    func save(_ tokens: XAITokens) {
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
            throw AIProviderError.authenticationFailed(String(localized: "Not signed in to xAI."))
        }
        if !tokens.isExpired {
            return tokens.accessToken
        }
        return try await refresh(using: tokens.refreshToken).accessToken
    }

    func forceRefresh() async throws -> String {
        guard let tokens = loadTokens() else {
            throw AIProviderError.authenticationFailed(String(localized: "Not signed in to xAI."))
        }
        return try await refresh(using: tokens.refreshToken).accessToken
    }

    private func refresh(using refreshToken: String) async throws -> XAITokens {
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task<XAITokens, Error> {
            let response = try await refresher.refresh(refreshToken: refreshToken)
            return persistRefreshed(response)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch {
            if case AIProviderError.authenticationFailed = error {
                Self.logger.notice("xAI refresh rejected; clearing stored session")
                clear()
            }
            throw error
        }
    }

    private func persistRefreshed(_ response: XAITokenResponse) -> XAITokens {
        let previous = loadTokens()
        let email = response.idToken.isEmpty
            ? (previous?.email ?? "")
            : XAIIdentity.email(fromIDToken: response.idToken)
        let tokens = XAITokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken.isEmpty ? (previous?.refreshToken ?? "") : response.refreshToken,
            idToken: response.idToken.isEmpty ? (previous?.idToken ?? "") : response.idToken,
            email: email.isEmpty ? (previous?.email ?? "") : email,
            expiresAt: response.expiresAt
        )
        persist(tokens)
        return tokens
    }

    private func persist(_ tokens: XAITokens) {
        cached = tokens
        guard let data = try? JSONEncoder().encode(tokens),
              let json = String(data: data, encoding: .utf8) else {
            Self.logger.error("Failed to encode xAI tokens for Keychain")
            return
        }
        keychain.writeString(json, forKey: Self.storageKey)
    }

    private func loadTokens() -> XAITokens? {
        if let cached {
            return cached
        }
        guard case .found(let json) = keychain.readStringResult(forKey: Self.storageKey),
              let data = json.data(using: .utf8),
              let tokens = try? JSONDecoder().decode(XAITokens.self, from: data) else {
            return nil
        }
        cached = tokens
        return tokens
    }
}
