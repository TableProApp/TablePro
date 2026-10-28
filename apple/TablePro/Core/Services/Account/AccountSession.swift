//
//  AccountSession.swift
//  TablePro
//

import Foundation
import os

internal struct AccessToken: Equatable, Sendable {
    let value: String
    let expiresAt: Date
    let deviceID: String?
    let isFromLicenseKey: Bool

    init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
        let claims = Self.claims(of: value)
        self.deviceID = claims["dev"] as? String
        self.isFromLicenseKey = claims["auth_method"] as? String == "license_key"
    }

    // The API checks the signature; the app only reads which device the token names.
    private static func claims(of token: String) -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = Base64URL.decode(parts[1]) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
    }
}

// Refresh token in the Keychain, access token in memory, one refresh in flight at a time.
internal actor AccountSession {
    static let refreshTokenKey = "com.TablePro.account.refreshToken"

    private static let logger = Logger(subsystem: "com.TablePro", category: "AccountSession")
    // Refreshed this long before it expires, so a request never leaves with a token about to lapse.
    private static let expiryMargin: TimeInterval = 60

    private let client: OAuthTokenClient
    private let keychain: any KeychainStoring
    private let now: @Sendable () -> Date
    private var access: AccessToken?
    private var refreshTask: Task<AccessToken, Error>?

    init(client: OAuthTokenClient, keychain: any KeychainStoring, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.keychain = keychain
        self.now = now
    }

    nonisolated var isSignedIn: Bool {
        storedRefreshToken != nil
    }

    func completeSignIn(_ request: AuthorizationRequest, callback: URL) async throws(AccountError) {
        let code = try request.code(from: callback)
        let tokens = try await client.exchangeCode(code, verifier: request.verifier)
        try adopt(tokens)
    }

    func signIn(licenseKey: String, machine: MachineDescription) async throws(AccountError) {
        let tokens = try await client.exchangeLicenseKey(licenseKey, machine: machine)
        try adopt(tokens)
    }

    func accessToken() async throws(AccountError) -> AccessToken {
        if let access, access.expiresAt.timeIntervalSince(now()) > Self.expiryMargin {
            return access
        }
        return try await refresh(replacing: access)
    }

    // After registering the device, so the next access token names it.
    func refreshNow() async throws(AccountError) -> AccessToken {
        try await refresh(replacing: access)
    }

    // A caller that saw `stale` refused gets the token another caller already refreshed, if any.
    func refresh(replacing stale: AccessToken?) async throws(AccountError) -> AccessToken {
        if let access, access != stale, access.expiresAt.timeIntervalSince(now()) > Self.expiryMargin {
            return access
        }
        if let refreshTask {
            return try await Self.value(of: refreshTask)
        }
        guard let refreshToken = storedRefreshToken else {
            throw .signedOut
        }
        let task = Task { [client] () async throws -> AccessToken in
            do throws(AccountError) {
                return try self.adopt(await client.refresh(refreshToken))
            } catch .oauth("invalid_grant", _) {
                Self.logger.notice("The refresh token was refused; signing out on this Mac")
                self.discard()
                throw AccountError.signedOut
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await Self.value(of: task)
    }

    func signOut() async {
        if let refreshToken = storedRefreshToken {
            do {
                try await client.revoke(refreshToken)
            } catch {
                Self.logger.warning("Revoking the refresh token failed: \(error.publicLogShape, privacy: .public)")
            }
        }
        discard()
    }

    func discard() {
        refreshTask?.cancel()
        refreshTask = nil
        access = nil
        keychain.delete(forKey: Self.refreshTokenKey)
    }

    @discardableResult
    private func adopt(_ tokens: OAuthTokens) throws(AccountError) -> AccessToken {
        if let refreshToken = tokens.refreshToken, !refreshToken.isEmpty {
            guard keychain.writeString(refreshToken, forKey: Self.refreshTokenKey) else {
                throw .invalidResponse
            }
        } else if storedRefreshToken == nil {
            throw .invalidResponse
        }
        let token = AccessToken(value: tokens.accessToken, expiresAt: now().addingTimeInterval(tokens.expiresIn))
        access = token
        return token
    }

    nonisolated private var storedRefreshToken: String? {
        guard case .found(let token) = keychain.readStringResult(forKey: Self.refreshTokenKey), !token.isEmpty else {
            return nil
        }
        return token
    }

    private static func value(of task: Task<AccessToken, Error>) async throws(AccountError) -> AccessToken {
        do {
            return try await task.value
        } catch let error as AccountError {
            throw error
        } catch {
            throw .network(error.localizedDescription)
        }
    }
}
