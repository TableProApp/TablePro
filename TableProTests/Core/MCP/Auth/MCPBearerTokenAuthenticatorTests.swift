//
//  MCPBearerTokenAuthenticatorTests.swift
//  TableProTests
//
//  The failure counter is keyed on the attacker, not on the credential the attacker presented.
//  Keying it on the presented token let one address walk the whole token space without ever
//  filling a bucket, and a request with no Authorization header at all was never counted. The
//  challenge is a structured value now (RFC 6750 `WWW-Authenticate`), so the realm survives beside
//  the error rather than being spliced into one string.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

actor FakeMCPTokenStore: MCPTokenStoreProtocol {
    private var tokens: [String: MCPValidatedToken] = [:]
    private var expired: Set<String> = []
    private var revoked: Set<String> = []
    private var presented: [String] = []

    func register(_ plaintext: String, validated: MCPValidatedToken) {
        tokens[plaintext] = validated
    }

    func markExpired(_ plaintext: String) {
        expired.insert(plaintext)
    }

    func markRevoked(_ plaintext: String) {
        revoked.insert(plaintext)
    }

    func presentedTokens() -> [String] {
        presented
    }

    func validateBearerToken(_ token: String) async -> Result<MCPValidatedToken, MCPTokenValidationError> {
        presented.append(token)
        if expired.contains(token) {
            return .failure(.expired)
        }
        if revoked.contains(token) {
            return .failure(.revoked)
        }
        if let validated = tokens[token] {
            return .success(validated)
        }
        return .failure(.unknownToken)
    }
}

@Suite("MCP Bearer Token Authenticator")
struct MCPBearerTokenAuthenticatorTests {
    private func makeValidated(
        label: String = "test",
        scopes: Set<MCPScope> = MCPScope.readOnlySet,
        connectionAccess: ConnectionAccess = .all,
        expiresAt: Date? = nil
    ) -> MCPValidatedToken {
        MCPValidatedToken(
            tokenId: UUID(),
            label: label,
            scopes: scopes,
            connectionAccess: connectionAccess,
            issuedAt: Date(timeIntervalSince1970: 1_000_000),
            expiresAt: expiresAt
        )
    }

    private func makeAuthenticator(
        store: FakeMCPTokenStore,
        clock: MCPTestClock = MCPTestClock()
    ) -> (MCPBearerTokenAuthenticator, MCPRateLimiter) {
        let limiter = MCPRateLimiter(clock: clock)
        return (MCPBearerTokenAuthenticator(tokenStore: store, rateLimiter: limiter, clock: clock), limiter)
    }

    private func denial(_ decision: MCPAuthDecision) -> MCPAuthDenialReason? {
        guard case .deny(let reason) = decision else { return nil }
        return reason
    }

    @Test("A missing Authorization header is answered with a bearer challenge naming the realm")
    func missingHeaderChallengesWithRealm() async throws {
        let (authenticator, _) = makeAuthenticator(store: FakeMCPTokenStore())

        let decision = await authenticator.authenticate(authorizationHeader: nil, clientAddress: .loopback)

        let reason = try #require(denial(decision))
        #expect(reason.kind == .unauthenticated)
        #expect(reason.httpStatus == 401)
        #expect(reason.challenge?.realm == "TablePro")
        #expect(reason.challenge?.headerValue == "Bearer realm=\"TablePro\"")
    }

    @Test("An empty Authorization header is not a credential")
    func emptyHeaderIsUnauthenticated() async throws {
        let (authenticator, _) = makeAuthenticator(store: FakeMCPTokenStore())

        let decision = await authenticator.authenticate(authorizationHeader: "", clientAddress: .loopback)

        let reason = try #require(denial(decision))
        #expect(reason.kind == .unauthenticated)
        #expect(reason.logMessage == "missing_authorization_header")
    }

    @Test("A non-bearer scheme never reaches the token store")
    func nonBearerSchemeIsRejectedBeforeValidation() async throws {
        let store = FakeMCPTokenStore()
        let (authenticator, _) = makeAuthenticator(store: store)

        let decision = await authenticator.authenticate(
            authorizationHeader: "Basic dXNlcjpwYXNz",
            clientAddress: .loopback
        )

        let reason = try #require(denial(decision))
        #expect(reason.kind == .unauthenticated)
        #expect(reason.logMessage == "invalid_authorization_scheme")
        #expect(await store.presentedTokens().isEmpty)
    }

    @Test("A valid token becomes a principal carrying its scopes and connection scope")
    func validTokenBecomesPrincipal() async throws {
        let store = FakeMCPTokenStore()
        let allowed = UUID()
        let plaintext = "tp_validtoken123"
        await store.register(
            plaintext,
            validated: makeValidated(
                label: "Token A",
                scopes: MCPScope.readWriteSet,
                connectionAccess: .limited([allowed])
            )
        )
        let (authenticator, _) = makeAuthenticator(store: store)

        let decision = await authenticator.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .loopback
        )

        guard case .allow(let principal) = decision else {
            Issue.record("Expected allow, got \(decision)")
            return
        }
        #expect(principal.metadata.label == "Token A")
        #expect(principal.scopes == MCPScope.readWriteSet)
        #expect(principal.connectionAccess.allows(allowed))
        #expect(principal.connectionAccess.allows(UUID()) == false)
        #expect(principal.isAnonymous == false)
    }

    @Test("The principal fingerprint is a digest, never the presented token")
    func fingerprintIsADigest() async throws {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_super_secret_material"
        await store.register(plaintext, validated: makeValidated())
        let (authenticator, _) = makeAuthenticator(store: store)

        let decision = await authenticator.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .loopback
        )

        guard case .allow(let principal) = decision else {
            Issue.record("Expected allow, got \(decision)")
            return
        }
        #expect(principal.tokenFingerprint.count == 16)
        let satisfiesAll = principal.tokenFingerprint.allSatisfy { $0.isHexDigit }
        #expect(satisfiesAll)
        #expect(principal.tokenFingerprint.contains("secret") == false)
        #expect(plaintext.contains(principal.tokenFingerprint) == false)
    }

    @Test("The bearer scheme is matched case-insensitively")
    func bearerSchemeIsCaseInsensitive() async {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_token"
        await store.register(plaintext, validated: makeValidated())
        let (authenticator, _) = makeAuthenticator(store: store)

        let decision = await authenticator.authenticate(
            authorizationHeader: "bEaReR \(plaintext)",
            clientAddress: .loopback
        )

        guard case .allow = decision else {
            Issue.record("Expected allow, got \(decision)")
            return
        }
    }

    @Test("An expired token is refused with an invalid_token challenge that keeps the realm")
    func expiredTokenChallenge() async throws {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_expired"
        await store.register(plaintext, validated: makeValidated())
        await store.markExpired(plaintext)
        let (authenticator, _) = makeAuthenticator(store: store)

        let decision = await authenticator.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .loopback
        )

        let reason = try #require(denial(decision))
        #expect(reason.kind == .tokenExpired)
        #expect(reason.httpStatus == 401)
        #expect(reason.logMessage == "token_expired")
        let challenge = try #require(reason.challenge)
        #expect(challenge.realm == "TablePro")
        #expect(challenge.error == "invalid_token")
        #expect(challenge.headerValue.contains("realm=\"TablePro\""))
        #expect(challenge.headerValue.contains("error=\"invalid_token\""))
    }

    @Test("A revoked token is refused as invalid")
    func revokedTokenIsRefused() async throws {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_revoked"
        await store.register(plaintext, validated: makeValidated())
        await store.markRevoked(plaintext)
        let (authenticator, _) = makeAuthenticator(store: store)

        let decision = await authenticator.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .loopback
        )

        let reason = try #require(denial(decision))
        #expect(reason.kind == .tokenInvalid)
        #expect(reason.httpStatus == 401)
        #expect(reason.logMessage == "token_revoked")
    }

    @Test("Five different wrong tokens from one address trip the lockout")
    func distinctWrongTokensShareTheAttackerBucket() async throws {
        let (authenticator, _) = makeAuthenticator(store: FakeMCPTokenStore())

        for index in 0..<4 {
            let decision = await authenticator.authenticate(
                authorizationHeader: "Bearer tp_guess_\(index)",
                clientAddress: .remote("203.0.113.9")
            )
            #expect(denial(decision)?.httpStatus == 401)
        }

        let final = await authenticator.authenticate(
            authorizationHeader: "Bearer tp_guess_4",
            clientAddress: .remote("203.0.113.9")
        )

        let reason = try #require(denial(final))
        #expect(reason.kind == .rateLimited)
        #expect(reason.httpStatus == 429)
        #expect((reason.retryAfterSeconds ?? 0) > 0)
    }

    @Test("Requests with no Authorization header at all are counted as failures")
    func missingHeaderCountsTowardsTheLockout() async throws {
        let (authenticator, _) = makeAuthenticator(store: FakeMCPTokenStore())

        for _ in 0..<4 {
            _ = await authenticator.authenticate(authorizationHeader: nil, clientAddress: .loopback)
        }
        let final = await authenticator.authenticate(authorizationHeader: nil, clientAddress: .loopback)

        let reason = try #require(denial(final))
        #expect(reason.kind == .rateLimited)
    }

    @Test("A locked address is refused before its token is even looked up")
    func lockoutPrecedesValidation() async throws {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_good"
        await store.register(plaintext, validated: makeValidated())
        let (authenticator, _) = makeAuthenticator(store: store)

        for index in 0..<5 {
            _ = await authenticator.authenticate(
                authorizationHeader: "Bearer tp_wrong_\(index)",
                clientAddress: .loopback
            )
        }
        let presentedBeforeLockout = await store.presentedTokens().count

        let decision = await authenticator.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .loopback
        )

        let reason = try #require(denial(decision))
        #expect(reason.kind == .rateLimited)
        #expect(await store.presentedTokens().count == presentedBeforeLockout)
    }

    @Test("The lockout is scoped to the address that earned it")
    func lockoutDoesNotFollowTheTokenToAnotherAddress() async {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_token"
        await store.register(plaintext, validated: makeValidated())
        let (authenticator, _) = makeAuthenticator(store: store)

        for index in 0..<5 {
            _ = await authenticator.authenticate(
                authorizationHeader: "Bearer tp_wrong_\(index)",
                clientAddress: .loopback
            )
        }

        let decision = await authenticator.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .remote("10.0.0.1")
        )

        guard case .allow = decision else {
            Issue.record("Expected allow from an address that has not failed, got \(decision)")
            return
        }
    }

    @Test("The lockout lifts once its window elapses")
    func lockoutExpires() async {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_token"
        await store.register(plaintext, validated: makeValidated())
        let clock = MCPTestClock()
        let (authenticator, _) = makeAuthenticator(store: store, clock: clock)

        for index in 0..<5 {
            _ = await authenticator.authenticate(
                authorizationHeader: "Bearer tp_wrong_\(index)",
                clientAddress: .loopback
            )
        }
        await clock.advance(by: .seconds(301))

        let decision = await authenticator.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .loopback
        )

        guard case .allow = decision else {
            Issue.record("Expected allow after the lockout expired, got \(decision)")
            return
        }
    }

    @Test("A success clears the failures that address had accumulated")
    func successClearsTheAddressBucket() async {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_good"
        await store.register(plaintext, validated: makeValidated())
        let (authenticator, limiter) = makeAuthenticator(store: store)

        for index in 0..<3 {
            _ = await authenticator.authenticate(
                authorizationHeader: "Bearer tp_wrong_\(index)",
                clientAddress: .loopback
            )
        }
        _ = await authenticator.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .loopback
        )

        for index in 3..<7 {
            let decision = await authenticator.authenticate(
                authorizationHeader: "Bearer tp_wrong_\(index)",
                clientAddress: .loopback
            )
            #expect(denial(decision)?.kind == .tokenInvalid)
        }
        #expect(await limiter.isLocked(key: .authFailure(address: .loopback)) == false)
    }

    @Test("A denial repeats no token material back to the caller")
    func denialCarriesNoTokenMaterial() async throws {
        let plaintext = "tp_material_that_must_not_echo"
        let fingerprint = MCPBearerTokenAuthenticator.fingerprint(of: plaintext)
        let (authenticator, _) = makeAuthenticator(store: FakeMCPTokenStore())

        let decision = await authenticator.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .loopback
        )

        let reason = try #require(denial(decision))
        let rendered = [reason.logMessage, reason.challenge?.headerValue ?? ""].joined(separator: " ")
        #expect(rendered.contains(plaintext) == false)
        #expect(rendered.contains(fingerprint) == false)
        #expect(rendered.contains(String(plaintext.prefix(8))) == false)
    }

    @Test("A bearer header with no value is not a token")
    func emptyBearerValueIsRejected() {
        #expect(MCPBearerTokenAuthenticator.parseBearerToken("Bearer") == nil)
        #expect(MCPBearerTokenAuthenticator.parseBearerToken("Bearer   ") == nil)
        #expect(MCPBearerTokenAuthenticator.parseBearerToken("  Bearer tp_abc  ") == "tp_abc")
    }
}
