//
//  VaultAuthenticator.swift
//  TablePro
//

import AppKit
import Foundation
import os

struct VaultToken: Equatable, Sendable {
    let value: String
    let source: VaultTokenSource
    // Nil when the token never expires.
    let expiresAt: ContinuousClock.Instant?
    let renewable: Bool
    // The lifetime Vault granted with the last login or renewal.
    var grantedTTL: Duration?

    func remaining(at now: ContinuousClock.Instant) -> Duration? {
        expiresAt.map { now.duration(to: $0) }
    }

    // A token that has spent most of its life gives a new lease too little time; a role that only issues short
    // tokens gets them as they are, or every sign-in would ask for another one.
    func isNearItsEnd(at now: ContinuousClock.Instant, floor: Duration) -> Bool {
        guard let remaining = remaining(at: now) else { return false }
        return remaining < min(floor, (grantedTTL ?? floor) / 2)
    }
}

// Minted tokens (AppRole, OIDC) live in memory only, for this launch.
actor VaultAuthenticator {
    static let shared = VaultAuthenticator()

    static let oidcRedirectURI = "http://localhost:8250/oidc/callback"

    private struct LoginKey: Hashable {
        let endpoint: VaultEndpoint
        let method: VaultAuthMethod
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "VaultAuthenticator")
    private static let expiryMargin: Duration = .seconds(5)
    private static let oidcCallbackTimeout: Duration = .seconds(300)

    private let transport: any VaultTransport
    private let environment: @Sendable () -> [String: String]
    private let readFile: @Sendable (String) -> String?
    private let now: @Sendable () -> ContinuousClock.Instant
    private let openURL: @Sendable (URL) async -> Void
    private let makeCallbackReceiver: @Sendable () -> any VaultOIDCCallbackReceiving

    private var minted: [LoginKey: VaultToken] = [:]
    private var oidcSignIns: [LoginKey: Task<VaultToken, Error>] = [:]

    init(
        transport: any VaultTransport = URLSessionVaultTransport.shared,
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        readFile: @escaping @Sendable (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        openURL: @escaping @Sendable (URL) async -> Void = { url in
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        },
        makeCallbackReceiver: @escaping @Sendable () -> any VaultOIDCCallbackReceiving = { VaultOIDCLoopback() }
    ) {
        self.transport = transport
        self.environment = environment
        self.readFile = readFile
        self.now = now
        self.openURL = openURL
        self.makeCallbackReceiver = makeCallbackReceiver
    }

    nonisolated var currentEnvironment: [String: String] { environment() }

    nonisolated var currentInstant: ContinuousClock.Instant { now() }

    // `validFor` renews a minted token that would expire sooner: Vault revokes a token's leases when it expires.
    func token(
        for method: VaultAuthMethod,
        endpoint: VaultEndpoint,
        interactive: Bool,
        validFor: Duration? = nil
    ) async throws -> VaultToken {
        switch method {
        case .token:
            return try await userToken(endpoint: endpoint)
        case let .appRole(mount, roleId, secretIdPath):
            let key = LoginKey(endpoint: endpoint, method: method)
            if let cached = await reusable(key, validFor: validFor) { return cached }
            let token = try await appRoleLogin(endpoint: endpoint, mount: mount, roleId: roleId, secretIdPath: secretIdPath)
            minted[key] = token
            return token
        case let .oidc(mount, role):
            let key = LoginKey(endpoint: endpoint, method: method)
            if let cached = await reusable(key, validFor: validFor) { return cached }
            let login = VaultOIDCLogin(endpoint: endpoint, mount: mount, role: role)
            guard interactive else { throw VaultError.oidcSignInRequired(login) }
            return try await signIn(login)
        }
    }

    func forget(_ method: VaultAuthMethod, endpoint: VaultEndpoint) {
        minted[LoginKey(endpoint: endpoint, method: method)] = nil
    }

    // A lease renewer that renewed the cached token reports it, so the next sign-in sees the new expiry.
    func adopt(_ renewed: VaultToken, for method: VaultAuthMethod, endpoint: VaultEndpoint) {
        let key = LoginKey(endpoint: endpoint, method: method)
        guard minted[key]?.value == renewed.value else { return }
        minted[key] = renewed
    }

    // Concurrent callers for one login share it: the callback port takes one listener.
    @discardableResult
    func signIn(_ login: VaultOIDCLogin) async throws -> VaultToken {
        let key = LoginKey(endpoint: login.endpoint, method: .oidc(mount: login.mount, role: login.role))
        if let running = oidcSignIns[key] {
            return try await running.value
        }
        let task = Task { try await self.performOIDCSignIn(login) }
        oidcSignIns[key] = task
        defer { oidcSignIns[key] = nil }
        let token = try await task.value
        minted[key] = token
        return token
    }

    // MARK: - Methods

    private func userToken(endpoint: VaultEndpoint) async throws -> VaultToken {
        let source: VaultTokenSource
        let value: String
        if let fromEnvironment = environment()["VAULT_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fromEnvironment.isEmpty {
            source = .environment
            value = fromEnvironment
        } else if let fromFile = readFile(Self.tokenFilePath)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fromFile.isEmpty {
            source = .tokenFile
            value = fromFile
        } else {
            throw VaultError.noToken
        }

        let grant: VaultTokenGrant
        do {
            grant = try await VaultClient(endpoint: endpoint, transport: transport).lookupSelf(token: value)
        } catch let error as VaultRequestError {
            throw VaultError.tokenRejected(source, error.message)
        }
        // The user owns this token, so it is never renewed here.
        return VaultToken(
            value: value,
            source: source,
            expiresAt: grant.ttl.map { now() + $0 },
            renewable: false,
            grantedTTL: grant.ttl
        )
    }

    private func appRoleLogin(
        endpoint: VaultEndpoint,
        mount: String,
        roleId: String,
        secretIdPath: String
    ) async throws -> VaultToken {
        let path = (secretIdPath as NSString).expandingTildeInPath
        guard let secretId = readFile(path)?.trimmingCharacters(in: .whitespacesAndNewlines), !secretId.isEmpty else {
            throw VaultError.secretIdUnreadable(path)
        }
        let grant: VaultTokenGrant
        do {
            grant = try await VaultClient(endpoint: endpoint, transport: transport)
                .appRoleLogin(mount: mount, roleId: roleId, secretId: secretId)
        } catch let error as VaultRequestError {
            throw VaultError.tokenRejected(.appRole, error.message)
        }
        return token(from: grant, source: .appRole)
    }

    private func performOIDCSignIn(_ login: VaultOIDCLogin) async throws -> VaultToken {
        let receiver = makeCallbackReceiver()
        try await receiver.start()
        defer { receiver.stop() }

        let client = VaultClient(endpoint: login.endpoint, transport: transport)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let authURL: URL
        do {
            authURL = try await client.oidcAuthURL(
                mount: login.mount,
                role: login.role,
                redirectURI: Self.oidcRedirectURI,
                clientNonce: nonce
            )
        } catch let error as VaultRequestError {
            throw VaultError.oidcFailed(error.message)
        }
        await openURL(authURL)

        let parameters = try await receiver.callback(timeout: Self.oidcCallbackTimeout)
        if let error = parameters["error"] {
            throw VaultError.oidcFailed(parameters["error_description"] ?? error)
        }
        guard let state = parameters["state"], let code = parameters["code"], !code.isEmpty else {
            throw VaultError.oidcFailed(String(localized: "The browser returned no authorization code."))
        }
        do {
            let grant = try await client.oidcCallback(mount: login.mount, state: state, code: code, clientNonce: nonce)
            Self.logger.info("Vault OIDC sign-in finished")
            return token(from: grant, source: .oidc)
        } catch let error as VaultRequestError {
            throw VaultError.oidcFailed(error.message)
        }
    }

    // MARK: - Minted tokens

    private func reusable(_ key: LoginKey, validFor: Duration?) async -> VaultToken? {
        guard let cached = minted[key] else { return nil }
        let current = now()
        if let expiresAt = cached.expiresAt, expiresAt <= current + Self.expiryMargin {
            minted[key] = nil
            return nil
        }
        guard let validFor, cached.renewable, let expiresAt = cached.expiresAt, expiresAt < current + validFor else {
            return cached
        }
        do {
            let grant = try await VaultClient(endpoint: key.endpoint, transport: transport)
                .renewSelf(token: cached.value, increment: validFor)
            let renewed = token(from: grant, source: cached.source)
            minted[key] = renewed
            return renewed
        } catch let error as VaultRequestError where error.isPermissionDenied {
            minted[key] = nil
            return nil
        } catch {
            Self.logger.warning("Could not renew a Vault token: \(error.publicLogShape, privacy: .public)")
            return cached
        }
    }

    private func token(from grant: VaultTokenGrant, source: VaultTokenSource) -> VaultToken {
        VaultToken(
            value: grant.token,
            source: source,
            expiresAt: grant.ttl.map { now() + $0 },
            renewable: grant.renewable,
            grantedTTL: grant.ttl
        )
    }

    private static var tokenFilePath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".vault-token")
    }
}
