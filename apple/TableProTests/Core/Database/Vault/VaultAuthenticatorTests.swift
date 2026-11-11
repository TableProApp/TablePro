//
//  VaultAuthenticatorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct VaultAuthenticatorTests {
    private let endpoint = VaultFixtures.endpoint

    @Test("VAULT_TOKEN wins over ~/.vault-token, as it does for the vault CLI")
    func environmentTokenFirst() async throws {
        let transport = VaultFakeTransport()
        transport.reply("GET", "auth/token/lookup-self", VaultFixtures.lookupReply(ttl: 600))
        let authenticator = VaultFixtures.authenticator(
            transport: transport,
            environment: ["VAULT_TOKEN": " env-token\n"],
            files: [".vault-token": "file-token"]
        )

        let token = try await authenticator.token(for: .token, endpoint: endpoint, interactive: false)

        #expect(token.value == "env-token")
        #expect(token.source == .environment)
        #expect(token.expiresAt != nil)
        #expect(transport.requests.first?.token == "env-token")
    }

    @Test("Without VAULT_TOKEN the token comes from ~/.vault-token")
    func tokenFile() async throws {
        let transport = VaultFakeTransport()
        transport.reply("GET", "auth/token/lookup-self", VaultFixtures.lookupReply(ttl: 0))
        let authenticator = VaultFixtures.authenticator(transport: transport, environment: [:], files: [".vault-token": "file-token\n"])

        let token = try await authenticator.token(for: .token, endpoint: endpoint, interactive: false)

        #expect(token.value == "file-token")
        #expect(token.source == .tokenFile)
        #expect(token.expiresAt == nil)
    }

    @Test("No token anywhere says where one is looked for")
    func noToken() async {
        let authenticator = VaultFixtures.authenticator(transport: VaultFakeTransport(), environment: [:])

        await #expect(throws: VaultError.noToken) {
            try await authenticator.token(for: .token, endpoint: endpoint, interactive: false)
        }
    }

    @Test("A rejected token names where it came from", arguments: [
        (["VAULT_TOKEN": "bad"], [String: String](), VaultTokenSource.environment),
        ([String: String](), [".vault-token": "bad"], VaultTokenSource.tokenFile),
    ])
    func rejectedTokenNamesSource(environment: [String: String], files: [String: String], source: VaultTokenSource) async {
        let transport = VaultFakeTransport()
        transport.reply("GET", "auth/token/lookup-self", status: 403, #"{"errors":["permission denied"]}"#)
        let authenticator = VaultFixtures.authenticator(transport: transport, environment: environment, files: files)

        await #expect(throws: VaultError.tokenRejected(source, "permission denied")) {
            try await authenticator.token(for: .token, endpoint: endpoint, interactive: false)
        }
    }

    @Test("AppRole logs in with the secret ID from its file, once, and reuses the token")
    func appRoleLogin() async throws {
        let transport = VaultFakeTransport()
        transport.reply("POST", "auth/approle/login", VaultFixtures.authReply(token: "approle-token"))
        let authenticator = VaultFixtures.authenticator(transport: transport, files: ["approle-secret-id": "secret-1\n"])
        let method = VaultAuthMethod.appRole(mount: "approle", roleId: "role-1", secretIdPath: "~/.vault/approle-secret-id")

        let first = try await authenticator.token(for: method, endpoint: endpoint, interactive: false)
        let second = try await authenticator.token(for: method, endpoint: endpoint, interactive: false)

        #expect(first.value == "approle-token")
        #expect(second == first)
        #expect(transport.requests(to: "auth/approle/login").count == 1)
        #expect(transport.requests.first?.body == ["role_id": "role-1", "secret_id": "secret-1"])
    }

    @Test("A missing secret ID file is named before anything is sent")
    func appRoleMissingSecret() async {
        let transport = VaultFakeTransport()
        let authenticator = VaultFixtures.authenticator(transport: transport)
        let method = VaultAuthMethod.appRole(mount: "approle", roleId: "role-1", secretIdPath: "/nowhere/secret-id")

        await #expect(throws: VaultError.secretIdUnreadable("/nowhere/secret-id")) {
            try await authenticator.token(for: method, endpoint: endpoint, interactive: false)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("A refused AppRole login says AppRole failed")
    func appRoleRefused() async {
        let transport = VaultFakeTransport()
        transport.reply("POST", "auth/approle/login", status: 400, #"{"errors":["invalid role or secret ID"]}"#)
        let authenticator = VaultFixtures.authenticator(transport: transport, files: ["secret-id": "wrong"])
        let method = VaultAuthMethod.appRole(mount: "approle", roleId: "role-1", secretIdPath: "/keys/secret-id")

        await #expect(throws: VaultError.tokenRejected(.appRole, "invalid role or secret ID")) {
            try await authenticator.token(for: method, endpoint: endpoint, interactive: false)
        }
    }

    @Test("A minted token about to expire is renewed when asked to cover a lease")
    func renewsMintedToken() async throws {
        let transport = VaultFakeTransport()
        transport.reply("POST", "auth/approle/login", VaultFixtures.authReply(token: "approle-token", ttl: 120))
        transport.reply("POST", "auth/token/renew-self", VaultFixtures.authReply(token: "approle-token", ttl: 3_600))
        let authenticator = VaultFixtures.authenticator(transport: transport, files: ["secret-id": "s"])
        let method = VaultAuthMethod.appRole(mount: "approle", roleId: "r", secretIdPath: "/keys/secret-id")

        _ = try await authenticator.token(for: method, endpoint: endpoint, interactive: false)
        let renewed = try await authenticator.token(for: method, endpoint: endpoint, interactive: false, validFor: .seconds(600))

        #expect(transport.requests(to: "auth/token/renew-self").count == 1)
        #expect(transport.requests(to: "auth/token/renew-self").first?.token == "approle-token")
        #expect(transport.requests(to: "auth/approle/login").count == 1)
        let remaining = try #require(renewed.remaining(at: .now))
        #expect(remaining > .seconds(3_000))
    }

    @Test("A token a lease renewer renewed replaces the cached one; another token does not")
    func adoptsRenewedToken() async throws {
        let transport = VaultFakeTransport()
        transport.reply("POST", "auth/approle/login", VaultFixtures.authReply(token: "approle-token", ttl: 120))
        let authenticator = VaultFixtures.authenticator(transport: transport, files: ["secret-id": "s"])
        let method = VaultAuthMethod.appRole(mount: "approle", roleId: "r", secretIdPath: "/keys/secret-id")
        let cached = try await authenticator.token(for: method, endpoint: endpoint, interactive: false)

        let stranger = VaultToken(value: "other", source: .appRole, expiresAt: nil, renewable: true)
        await authenticator.adopt(stranger, for: method, endpoint: endpoint)
        #expect(try await authenticator.token(for: method, endpoint: endpoint, interactive: false) == cached)

        let renewed = VaultToken(value: "approle-token", source: .appRole, expiresAt: .now + .seconds(3_600), renewable: true)
        await authenticator.adopt(renewed, for: method, endpoint: endpoint)
        #expect(try await authenticator.token(for: method, endpoint: endpoint, interactive: false) == renewed)
    }

    @Test("An OIDC login without a live token is not started by a background connect")
    func oidcNeedsSignIn() async {
        let transport = VaultFakeTransport()
        let authenticator = VaultFixtures.authenticator(transport: transport)

        await #expect(throws: VaultError.oidcSignInRequired(VaultOIDCLogin(endpoint: endpoint, mount: "oidc", role: "dba"))) {
            try await authenticator.token(for: .oidc(mount: "oidc", role: "dba"), endpoint: endpoint, interactive: false)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("OIDC sign-in opens the browser, trades the callback code for a token and keeps it for the launch")
    func oidcSignIn() async throws {
        let transport = VaultFakeTransport()
        transport.reply("POST", "auth/oidc/oidc/auth_url", #"{"data":{"auth_url":"https://idp.test/authorize?x=1&state=st"}}"#)
        transport.reply("GET", "auth/oidc/oidc/callback", VaultFixtures.authReply(token: "oidc-token", ttl: 3_600))
        let receiver = VaultFakeCallbackReceiver(parameters: ["state": "st", "code": "cd"])
        let opened = VaultFixtures.OpenedURLs()
        let authenticator = VaultFixtures.authenticator(transport: transport, receiver: receiver, opened: opened)
        let method = VaultAuthMethod.oidc(mount: "oidc", role: "dba")

        let token = try await authenticator.token(for: method, endpoint: endpoint, interactive: true)
        let again = try await authenticator.token(for: method, endpoint: endpoint, interactive: false)

        #expect(token.value == "oidc-token")
        #expect(again == token)
        #expect(opened.all.map(\.absoluteString) == ["https://idp.test/authorize?x=1&state=st"])
        #expect(receiver.wasStopped)
        #expect(receiver.expectedStates == ["st"])
        let authURLRequest = try #require(transport.requests(to: "auth/oidc/oidc/auth_url").first)
        #expect(authURLRequest.body["redirect_uri"] == "http://localhost:8250/oidc/callback")
        #expect(authURLRequest.body["role"] == "dba")
        let nonce = try #require(authURLRequest.body["client_nonce"])
        let callback = try #require(transport.requests(to: "auth/oidc/oidc/callback").first)
        #expect(callback.query?.contains("client_nonce=\(nonce)") == true)
        #expect(callback.query?.contains("code=cd") == true)
    }

    @Test("An identity provider error ends the OIDC sign-in with its description")
    func oidcProviderError() async {
        let transport = VaultFakeTransport()
        transport.reply("POST", "auth/oidc/oidc/auth_url", #"{"data":{"auth_url":"https://idp.test/authorize?state=st"}}"#)
        let receiver = VaultFakeCallbackReceiver(parameters: ["error": "access_denied", "error_description": "User cancelled"])
        let authenticator = VaultFixtures.authenticator(transport: transport, receiver: receiver)

        await #expect(throws: VaultError.oidcFailed("User cancelled")) {
            try await authenticator.token(for: .oidc(mount: "oidc", role: ""), endpoint: endpoint, interactive: true)
        }
        #expect(transport.requests(to: "auth/oidc/oidc/callback").isEmpty)
    }

    @Test("A sign-in page that is not a web address is refused before the browser opens anything", arguments: [
        "file:///System/Applications/Calculator.app",
        "shortcuts://run-shortcut?name=Deploy",
        "https:///no-host",
        "/authorize",
        "http://idp.example/authorize",
    ])
    func oidcRefusesNonWebSignInPage(authURL: String) async {
        let transport = VaultFakeTransport()
        transport.reply("POST", "auth/oidc/oidc/auth_url", #"{"data":{"auth_url":"\#(authURL)"}}"#)
        let receiver = VaultFakeCallbackReceiver(parameters: ["state": "st", "code": "cd"])
        let opened = VaultFixtures.OpenedURLs()
        let authenticator = VaultFixtures.authenticator(transport: transport, receiver: receiver, opened: opened)

        await #expect(throws: VaultError.self) {
            try await authenticator.token(for: .oidc(mount: "oidc", role: ""), endpoint: endpoint, interactive: true)
        }
        #expect(opened.all.isEmpty)
        #expect(transport.requests(to: "auth/oidc/oidc/callback").isEmpty)
    }

    @Test("A local identity provider over plain http on this Mac still opens")
    func oidcAllowsLoopbackSignInPage() async throws {
        let transport = VaultFakeTransport()
        transport.reply("POST", "auth/oidc/oidc/auth_url", #"{"data":{"auth_url":"http://127.0.0.1:5556/auth?x=1&state=st"}}"#)
        transport.reply("GET", "auth/oidc/oidc/callback", VaultFixtures.authReply(token: "oidc-token"))
        let receiver = VaultFakeCallbackReceiver(parameters: ["state": "st", "code": "cd"])
        let opened = VaultFixtures.OpenedURLs()
        let authenticator = VaultFixtures.authenticator(transport: transport, receiver: receiver, opened: opened)

        let token = try await authenticator.token(for: .oidc(mount: "oidc", role: ""), endpoint: endpoint, interactive: true)

        #expect(token.value == "oidc-token")
        #expect(opened.all.map { $0.absoluteString } == ["http://127.0.0.1:5556/auth?x=1&state=st"])
    }

    @Test("A sign-in page without a state is refused before the browser opens anything")
    func oidcRefusesSignInPageWithoutState() async {
        let transport = VaultFakeTransport()
        transport.reply("POST", "auth/oidc/oidc/auth_url", #"{"data":{"auth_url":"https://idp.test/authorize?x=1"}}"#)
        let receiver = VaultFakeCallbackReceiver(parameters: ["state": "st", "code": "cd"])
        let opened = VaultFixtures.OpenedURLs()
        let authenticator = VaultFixtures.authenticator(transport: transport, receiver: receiver, opened: opened)

        await #expect(throws: VaultError.self) {
            try await authenticator.token(for: .oidc(mount: "oidc", role: ""), endpoint: endpoint, interactive: true)
        }
        #expect(opened.all.isEmpty)
        #expect(receiver.expectedStates.isEmpty)
        #expect(transport.requests(to: "auth/oidc/oidc/callback").isEmpty)
    }

    @Test("The callback listener hands back the query of GET /oidc/callback carrying the expected state")
    func loopbackParsesCallback() {
        let head = Data("GET /oidc/callback?code=abc&state=xyz HTTP/1.1\r\nHost: localhost:8250\r\n\r\n".utf8)
        #expect(VaultOIDCLoopback.callbackParameters(in: head, expectedState: "xyz") == ["code": "abc", "state": "xyz"])

        let denied = Data("GET /oidc/callback?error=access_denied&error_description=User+cancelled&state=xyz HTTP/1.1\r\n\r\n".utf8)
        #expect(
            VaultOIDCLoopback.callbackParameters(in: denied, expectedState: "xyz")
                == ["error": "access_denied", "error_description": "User cancelled", "state": "xyz"]
        )

        let favicon = Data("GET /favicon.ico HTTP/1.1\r\nHost: localhost:8250\r\n\r\n".utf8)
        #expect(VaultOIDCLoopback.callbackParameters(in: favicon, expectedState: "xyz") == nil)

        let partial = Data("GET /oidc/callback?code=abc&state=xyz HTTP/1.1\r\nHost: local".utf8)
        #expect(VaultOIDCLoopback.callbackParameters(in: partial, expectedState: "xyz") == nil)
    }

    @Test("A callback without this sign-in's state is ignored", arguments: [
        "/oidc/callback?code=abc&state=forged",
        "/oidc/callback?code=abc",
        "/oidc/callback?code=abc&state=xyz&state=xyz",
        "/oidc/callback?error=access_denied&state=forged",
        "/oidc/callback?error=access_denied"
    ])
    func loopbackIgnoresStrayCallback(target: String) {
        let head = Data("GET \(target) HTTP/1.1\r\nHost: localhost:8250\r\n\r\n".utf8)
        #expect(VaultOIDCLoopback.callbackParameters(in: head, expectedState: "xyz") == nil)
    }

    @Test("A stray callback is answered and ignored, and the real one still ends the wait")
    func loopbackKeepsListeningAfterAStrayCallback() async throws {
        let loopback = VaultOIDCLoopback(expectedState: "xyz", port: 0)
        let port = try await loopback.startListening()
        defer { loopback.stop() }
        let parameters = Task { try await loopback.callback(timeout: .seconds(30)) }

        let forged = await Self.status(of: "/oidc/callback?code=forged&state=wrong", port: port)
        let redirect = await Self.status(of: "/oidc/callback?code=real&state=xyz", port: port)

        #expect([forged, redirect] == [400, 200])
        #expect(try await parameters.value == ["code": "real", "state": "xyz"])
    }

    private static func status(of target: String, port: UInt16) async -> Int? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(target)") else { return nil }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let request = URLRequest(url: url, timeoutInterval: 5)
        guard let (_, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse
        else {
            return nil
        }
        return httpResponse.statusCode
    }
}
