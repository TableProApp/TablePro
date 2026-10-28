//
//  AccountSessionTests.swift
//  TableProTests
//

import CryptoKit
import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

struct AccountSessionTests {
    private static let configuration = AccountConfiguration(
        accountURL: URL(string: "http://account.localhost:5284")!,
        apiURL: URL(string: "http://api.localhost:5284")!,
        entitlementKeys: []
    )

    private static func session(_ server: FakeAccountServer, keychain: InMemoryKeychain) -> AccountSession {
        AccountSession(
            client: OAuthTokenClient(configuration: configuration, send: { try await server.oauth($0) }),
            keychain: keychain
        )
    }

    private static func signedIn(_ server: FakeAccountServer, keychain: InMemoryKeychain) async throws -> AccountSession {
        let session = session(server, keychain: keychain)
        let request = AuthorizationRequest.make(configuration: configuration, machine: FakeAccountServer.machine)
        let callback = try #require(URL(string: "app.tablepro:/oauth/callback?code=code-1&state=\(request.state)"))
        try await session.completeSignIn(request, callback: callback)
        return session
    }

    @Test("The authorization URL asks for a PKCE S256 code for tablepro-macos and describes this Mac")
    func authorizationURL() throws {
        let request = AuthorizationRequest.make(configuration: Self.configuration, machine: FakeAccountServer.machine)
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.host == "account.localhost")
        #expect(components.path == "/oauth/authorize")
        #expect(query["client_id"] == "tablepro-macos")
        #expect(query["redirect_uri"] == "app.tablepro:/oauth/callback")
        #expect(query["response_type"] == "code")
        #expect(query["scope"] == "openid email offline_access app")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == Base64URL.encode(Data(SHA256.hash(data: Data(request.verifier.utf8)))))
        #expect(query["state"] == request.state)
        #expect(query["machine_name"] == "Test Mac")
        #expect(query["app_version"] == "2.0.0")
        #expect(query["os_version"] == "26.1")
    }

    @Test("A plus sign or an accent in the machine name survives form decoding")
    func formEncodingIsStrict() {
        #expect(OAuthTokenClient.formBody(["machine_name": "Đạt's Mac+Mini"])
            == "machine_name=%C4%90%E1%BA%A1t%27s%20Mac%2BMini")
    }

    @Test("A callback whose state does not match is refused before any code exchange")
    func stateMismatchIsRefused() async throws {
        let server = FakeAccountServer()
        let session = Self.session(server, keychain: InMemoryKeychain())
        let request = AuthorizationRequest.make(configuration: Self.configuration, machine: FakeAccountServer.machine)
        let forged = try #require(URL(string: "app.tablepro:/oauth/callback?code=code-1&state=other"))

        await #expect(throws: AccountError.stateMismatch) {
            try await session.completeSignIn(request, callback: forged)
        }
        #expect(await server.requests.isEmpty)
    }

    @Test("An error the server put in the callback is reported as an OAuth error")
    func callbackErrorIsReported() throws {
        let request = AuthorizationRequest.make(configuration: Self.configuration, machine: FakeAccountServer.machine)
        let callback = try #require(URL(string: "app.tablepro:/oauth/callback?error=access_denied&state=\(request.state)"))
        #expect(throws: AccountError.oauth("access_denied", description: nil)) {
            try request.code(from: callback)
        }
    }

    @Test("The code exchange sends the verifier and keeps the refresh token in the Keychain")
    func codeExchange() async throws {
        let server = FakeAccountServer()
        let keychain = InMemoryKeychain()
        let session = try await Self.signedIn(server, keychain: keychain)

        let exchange = try #require(await server.requests(to: "/oauth/token").first)
        #expect(exchange.form["grant_type"] == "authorization_code")
        #expect(exchange.form["client_id"] == "tablepro-macos")
        #expect(exchange.form["redirect_uri"] == "app.tablepro:/oauth/callback")
        #expect(exchange.form["code_verifier"]?.isEmpty == false)
        #expect(session.isSignedIn)
        guard case .found(let stored) = keychain.readStringResult(forKey: AccountSession.refreshTokenKey) else {
            Issue.record("No refresh token in the Keychain")
            return
        }
        #expect(stored.hasPrefix("refresh-"))
    }

    @Test("Concurrent callers share one refresh")
    func refreshIsSingleFlight() async throws {
        let server = FakeAccountServer()
        let keychain = InMemoryKeychain()
        let session = try await Self.signedIn(server, keychain: keychain)
        let refused = try await session.accessToken()
        let gate = AsyncGate()
        await server.set { $0.refreshGate = gate }

        async let first = session.refresh(replacing: refused)
        async let second = session.refresh(replacing: refused)
        async let third = session.refresh(replacing: refused)
        await gate.arrived(1)
        await gate.open()
        let tokens = try await [first, second, third]

        #expect(await server.refreshCount == 1)
        #expect(Set(tokens.map { $0.value }).count == 1)
        #expect(tokens[0] != refused)
    }

    @Test("A refused refresh token signs this Mac out and leaves no token behind")
    func refusedRefreshSignsOut() async throws {
        let server = FakeAccountServer()
        let keychain = InMemoryKeychain()
        let session = try await Self.signedIn(server, keychain: keychain)
        await server.set { $0.refusesRefresh = true }

        await #expect(throws: AccountError.signedOut) {
            try await session.refreshNow()
        }
        #expect(!session.isSignedIn)
        #expect(keychain.readStringResult(forKey: AccountSession.refreshTokenKey) == .notFound)
    }

    @Test("A refresh that cannot reach the server keeps the refresh token")
    func offlineRefreshKeepsTheToken() async throws {
        let server = FakeAccountServer()
        let keychain = InMemoryKeychain()
        let session = try await Self.signedIn(server, keychain: keychain)
        await server.set { $0.isOffline = true }

        await #expect(throws: AccountError.self) {
            try await session.refreshNow()
        }
        #expect(session.isSignedIn)
    }

    @Test("Sign-out revokes the refresh token at /oauth/revoke and forgets it")
    func signOutRevokes() async throws {
        let server = FakeAccountServer()
        let keychain = InMemoryKeychain()
        let session = try await Self.signedIn(server, keychain: keychain)
        guard case .found(let token) = keychain.readStringResult(forKey: AccountSession.refreshTokenKey) else {
            Issue.record("No refresh token in the Keychain")
            return
        }

        await session.signOut()

        let revoke = try #require(await server.requests(to: "/oauth/revoke").first)
        #expect(revoke.form["token"] == token)
        #expect(revoke.form["client_id"] == "tablepro-macos")
        #expect(!session.isSignedIn)
    }

    @Test("The license key exchange is an RFC 8693 token exchange that describes this Mac")
    func licenseKeyExchange() async throws {
        let server = FakeAccountServer()
        let session = Self.session(server, keychain: InMemoryKeychain())

        try await session.signIn(licenseKey: FakeAccountServer.validKey, machine: FakeAccountServer.machine)

        let exchange = try #require(await server.requests(to: "/oauth/token").first)
        #expect(exchange.form["grant_type"] == "urn:ietf:params:oauth:grant-type:token-exchange")
        #expect(exchange.form["subject_token"] == FakeAccountServer.validKey)
        #expect(exchange.form["subject_token_type"] == "https://account.tablepro.app/token-types/license-key")
        #expect(exchange.form["scope"] == "openid email offline_access app")
        #expect(exchange.form["machine_id"] == FakeAccountServer.machine.machineID)
        #expect(exchange.form["machine_name"] == "Test Mac")
        #expect(exchange.form["platform"] == "macos")
        #expect(exchange.form["app_version"] == "2.0.0")
        #expect(exchange.form["os_version"] == "26.1")
        let token = try await session.accessToken()
        #expect(token.deviceID == FakeAccountServer.deviceID)
        #expect(token.isFromLicenseKey)
    }
}
