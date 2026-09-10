//
//  MCPCompositeAuthenticatorTests.swift
//  TableProTests
//
//  Two rules meet here. The anonymous loopback principal is the weakest identity the server can
//  hand out, so it carries read scopes only and no issued token: a write or an admin operation is
//  refused for it whatever its scope set says. And presenting a credential opts out of anonymity
//  entirely, so a revoked or expired token is refused rather than silently downgraded to the
//  anonymous principal, which is how a token the user had revoked kept working.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("MCP Composite Authenticator")
struct MCPCompositeAuthenticatorTests {
    private func makeValidated(
        label: String = "test",
        scopes: Set<MCPScope> = MCPScope.readWriteSet,
        connectionAccess: ConnectionAccess = .all
    ) -> MCPValidatedToken {
        MCPValidatedToken(
            tokenId: UUID(),
            label: label,
            scopes: scopes,
            connectionAccess: connectionAccess,
            issuedAt: Date(timeIntervalSince1970: 1_000_000),
            expiresAt: nil
        )
    }

    private func makeComposite(
        _ store: FakeMCPTokenStore,
        requireAuthentication: Bool
    ) -> MCPCompositeAuthenticator {
        let clock = MCPTestClock()
        let bearer = MCPBearerTokenAuthenticator(
            tokenStore: store,
            rateLimiter: MCPRateLimiter(clock: clock),
            clock: clock
        )
        return MCPCompositeAuthenticator(bearer: bearer, requireAuthentication: requireAuthentication)
    }

    private func denial(_ decision: MCPAuthDecision) -> MCPAuthDenialReason? {
        guard case .deny(let reason) = decision else { return nil }
        return reason
    }

    @Test("Loopback with no credential and no requirement yields the anonymous principal")
    func anonymousOnLoopback() async throws {
        let composite = makeComposite(FakeMCPTokenStore(), requireAuthentication: false)

        let decision = await composite.authenticate(authorizationHeader: nil, clientAddress: .loopback)

        guard case .allow(let principal) = decision else {
            Issue.record("Expected allow, got \(decision)")
            return
        }
        #expect(principal == .anonymousLoopback)
        #expect(principal.tokenId == nil)
        #expect(principal.isAnonymous)
        #expect(principal.tokenFingerprint == MCPPrincipal.anonymousFingerprint)
    }

    @Test("The anonymous principal is read-only and carries no admin scope")
    func anonymousPrincipalIsReadOnly() {
        let anonymous = MCPPrincipal.anonymousLoopback

        #expect(anonymous.scopes == MCPScope.readOnlySet)
        #expect(anonymous.has(.toolsRead))
        #expect(anonymous.has(.resourcesRead))
        #expect(anonymous.has(.toolsWrite) == false)
        #expect(anonymous.has(.admin) == false)
    }

    @Test("A write or admin scope is refused for an anonymous principal even when it claims one")
    func anonymousCannotHoldPrivilegedScopes() throws {
        let overreaching = MCPPrincipal(
            tokenFingerprint: MCPPrincipal.anonymousFingerprint,
            tokenId: nil,
            scopes: Set(MCPScope.allCases),
            connectionAccess: .all,
            metadata: MCPPrincipalMetadata(label: "Anonymous", issuedAt: .distantPast, expiresAt: nil)
        )

        #expect(throws: MCPProtocolError.self) {
            try overreaching.requireScopes([.toolsWrite], reason: "write")
        }
        #expect(throws: MCPProtocolError.self) {
            try overreaching.requireScopes([.admin], reason: "admin")
        }
        try overreaching.requireScopes(MCPScope.readOnlySet, reason: "read")
    }

    @Test("A scope refusal names the missing scope in the WWW-Authenticate challenge")
    func scopeRefusalCarriesAChallenge() throws {
        let anonymous = MCPPrincipal.anonymousLoopback

        do {
            try anonymous.requireScopes([.toolsWrite], reason: "writing requires an issued token")
            Issue.record("Expected the write scope to be refused")
        } catch let error as MCPProtocolError {
            #expect(error.httpStatus.code == 403)
            let header = try #require(error.extraHeaders.first(where: { $0.0 == "WWW-Authenticate" })?.1)
            #expect(header.hasPrefix("Bearer "))
            #expect(header.contains("realm=\"TablePro\""))
            #expect(header.contains("error=\"insufficient_scope\""))
            #expect(header.contains("scope=\"tools:write\""))
        }
    }

    @Test("An unknown token on loopback is refused rather than downgraded to anonymous")
    func unknownTokenIsNotDowngraded() async throws {
        let composite = makeComposite(FakeMCPTokenStore(), requireAuthentication: false)

        let decision = await composite.authenticate(
            authorizationHeader: "Bearer tp_unknown",
            clientAddress: .loopback
        )

        let reason = try #require(denial(decision))
        #expect(reason.kind == .tokenInvalid)
    }

    @Test("A revoked token gets no access even when authentication is not required")
    func revokedTokenIsRefusedWithAuthenticationDisabled() async throws {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_revoked"
        await store.register(plaintext, validated: makeValidated())
        await store.markRevoked(plaintext)
        let composite = makeComposite(store, requireAuthentication: false)

        let decision = await composite.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .loopback
        )

        let reason = try #require(denial(decision))
        #expect(reason.kind == .tokenInvalid)
        #expect(reason.logMessage == "token_revoked")
    }

    @Test("An expired token gets no access even when authentication is not required")
    func expiredTokenIsRefusedWithAuthenticationDisabled() async throws {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_expired"
        await store.register(plaintext, validated: makeValidated())
        await store.markExpired(plaintext)
        let composite = makeComposite(store, requireAuthentication: false)

        let decision = await composite.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .loopback
        )

        let reason = try #require(denial(decision))
        #expect(reason.kind == .tokenExpired)
    }

    @Test("A valid token presented on loopback wins over the anonymous path")
    func presentedTokenTakesPrecedenceOverAnonymous() async {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_real"
        await store.register(plaintext, validated: makeValidated(label: "Token A"))
        let composite = makeComposite(store, requireAuthentication: false)

        let decision = await composite.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .loopback
        )

        guard case .allow(let principal) = decision else {
            Issue.record("Expected allow, got \(decision)")
            return
        }
        #expect(principal.metadata.label == "Token A")
        #expect(principal.tokenId != nil)
        #expect(principal.isAnonymous == false)
    }

    @Test("A remote client is never anonymous, whatever the requirement says")
    func remoteClientIsNeverAnonymous() async throws {
        let composite = makeComposite(FakeMCPTokenStore(), requireAuthentication: false)

        let decision = await composite.authenticate(
            authorizationHeader: nil,
            clientAddress: .remote("192.168.1.5")
        )

        let reason = try #require(denial(decision))
        #expect(reason.kind == .unauthenticated)
    }

    @Test("Requiring authentication removes the anonymous path on loopback")
    func requiringAuthenticationDeniesLoopbackWithoutCredential() async throws {
        let composite = makeComposite(FakeMCPTokenStore(), requireAuthentication: true)

        let decision = await composite.authenticate(authorizationHeader: nil, clientAddress: .loopback)

        let reason = try #require(denial(decision))
        #expect(reason.kind == .unauthenticated)
        #expect(reason.httpStatus == 401)
    }

    @Test("Requiring authentication accepts a valid token from a remote client")
    func remoteWithValidTokenIsAllowed() async {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_remote"
        await store.register(plaintext, validated: makeValidated(label: "Remote Token"))
        let composite = makeComposite(store, requireAuthentication: true)

        let decision = await composite.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .remote("192.168.1.5")
        )

        guard case .allow(let principal) = decision else {
            Issue.record("Expected allow, got \(decision)")
            return
        }
        #expect(principal.metadata.label == "Remote Token")
    }

    @Test("The in-app assistant principal is an issued identity, not an anonymous one")
    func inAppAssistantIsIssued() {
        let assistant = MCPPrincipal.inAppAssistant

        #expect(assistant.isAnonymous == false)
        #expect(assistant.tokenId == MCPPrincipal.inAppAssistantTokenId)
        #expect(assistant.has(.admin))
        #expect(assistant.ledgerKey != MCPPrincipal.anonymousLoopback.ledgerKey)
    }
}
