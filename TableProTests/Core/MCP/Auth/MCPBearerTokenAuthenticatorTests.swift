import Foundation
@testable import TablePro
import Testing

actor FakeMCPTokenStore: MCPTokenStoreProtocol {
    private var tokens: [String: MCPValidatedToken] = [:]
    private var expired: Set<String> = []
    private var revoked: Set<String> = []

    func register(_ plaintext: String, validated: MCPValidatedToken) {
        tokens[plaintext] = validated
    }

    func markExpired(_ plaintext: String) {
        expired.insert(plaintext)
    }

    func markRevoked(_ plaintext: String) {
        revoked.insert(plaintext)
    }

    func validateBearerToken(_ token: String) async -> Result<MCPValidatedToken, MCPTokenValidationError> {
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
    private func makePrincipal(label: String = "test", scopes: Set<MCPScope> = [.toolsRead]) -> MCPValidatedToken {
        MCPValidatedToken(
            tokenId: UUID(),
            label: label,
            scopes: scopes,
            issuedAt: Date(timeIntervalSince1970: 1_000_000),
            expiresAt: nil
        )
    }

    private func makeAuthenticator(
        store: FakeMCPTokenStore,
        clock: MCPTestClock = MCPTestClock()
    ) -> (MCPBearerTokenAuthenticator, MCPRateLimiter) {
        let limiter = MCPRateLimiter(clock: clock)
        let authenticator = MCPBearerTokenAuthenticator(tokenStore: store, rateLimiter: limiter)
        return (authenticator, limiter)
    }

    @Test("Missing header returns 401 with bearer challenge")
    func missingHeader() async {
        let store = FakeMCPTokenStore()
        let (authenticator, _) = makeAuthenticator(store: store)
        let decision = await authenticator.authenticate(
            authorizationHeader: nil,
            clientAddress: .loopback
        )
        guard case .deny(let reason) = decision else {
            Issue.record("Expected deny, got \(decision)")
            return
        }
        #expect(reason.httpStatus == 401)
        #expect(reason.challenge?.contains("Bearer") == true)
    }

    @Test("Empty header returns 401")
    func emptyHeader() async {
        let store = FakeMCPTokenStore()
        let (authenticator, _) = makeAuthenticator(store: store)
        let decision = await authenticator.authenticate(
            authorizationHeader: "",
            clientAddress: .loopback
        )
        guard case .deny(let reason) = decision else {
            Issue.record("Expected deny")
            return
        }
        #expect(reason.httpStatus == 401)
    }

    @Test("Bad scheme returns 401")
    func badScheme() async {
        let store = FakeMCPTokenStore()
        let (authenticator, _) = makeAuthenticator(store: store)
        let decision = await authenticator.authenticate(
            authorizationHeader: "Basic abc123",
            clientAddress: .loopback
        )
        guard case .deny(let reason) = decision else {
            Issue.record("Expected deny")
            return
        }
        #expect(reason.httpStatus == 401)
    }

    @Test("Valid token returns allow with principal")
    func validToken() async {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_validtoken123"
        await store.register(plaintext, validated: makePrincipal())
        let (authenticator, _) = makeAuthenticator(store: store)
        let decision = await authenticator.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .loopback
        )
        guard case .allow(let principal) = decision else {
            Issue.record("Expected allow, got \(decision)")
            return
        }
        #expect(principal.scopes.contains(.toolsRead))
        #expect(principal.tokenFingerprint.count == 8)
        #expect(!principal.tokenFingerprint.contains(plaintext))
    }

    @Test("Bearer scheme is case-insensitive")
    func bearerCaseInsensitive() async {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_token"
        await store.register(plaintext, validated: makePrincipal())
        let (authenticator, _) = makeAuthenticator(store: store)
        let decision = await authenticator.authenticate(
            authorizationHeader: "bEaReR \(plaintext)",
            clientAddress: .loopback
        )
        guard case .allow = decision else {
            Issue.record("Expected allow")
            return
        }
    }

    @Test("Expired token returns 401 expired")
    func expiredToken() async {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_expired"
        await store.register(plaintext, validated: makePrincipal())
        await store.markExpired(plaintext)
        let (authenticator, _) = makeAuthenticator(store: store)
        let decision = await authenticator.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .loopback
        )
        guard case .deny(let reason) = decision else {
            Issue.record("Expected deny")
            return
        }
        #expect(reason.httpStatus == 401)
        #expect(reason.logMessage == "token_expired")
    }

    @Test("Repeated bad token leads to rate limited 429")
    func repeatedBadTokenRateLimited() async {
        let store = FakeMCPTokenStore()
        let clock = MCPTestClock()
        let limiter = MCPRateLimiter(clock: clock)
        let authenticator = MCPBearerTokenAuthenticator(tokenStore: store, rateLimiter: limiter)

        let badToken = "tp_unknown"
        for _ in 0..<5 {
            _ = await authenticator.authenticate(
                authorizationHeader: "Bearer \(badToken)",
                clientAddress: .loopback
            )
        }
        let final = await authenticator.authenticate(
            authorizationHeader: "Bearer \(badToken)",
            clientAddress: .loopback
        )
        guard case .deny(let reason) = final else {
            Issue.record("Expected deny")
            return
        }
        #expect(reason.httpStatus == 429)
    }

    @Test("Successful auth resets rate limit bucket")
    func successResetsRateLimit() async {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_good"
        await store.register(plaintext, validated: makePrincipal())
        let clock = MCPTestClock()
        let limiter = MCPRateLimiter(clock: clock)
        let authenticator = MCPBearerTokenAuthenticator(tokenStore: store, rateLimiter: limiter)

        let goodHeader = "Bearer \(plaintext)"
        for _ in 0..<3 {
            _ = await authenticator.authenticate(
                authorizationHeader: goodHeader,
                clientAddress: .loopback
            )
        }
        let fingerprint = MCPBearerTokenAuthenticator.fingerprint(of: plaintext)
        let key = MCPRateLimitKey(clientAddress: .loopback, principalFingerprint: fingerprint)
        let locked = await limiter.isLocked(key: key)
        #expect(locked == false)
    }

    @Test("Different addresses with same token are isolated by rate limiter")
    func addressIsolation() async {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_token"
        await store.register(plaintext, validated: makePrincipal())
        let clock = MCPTestClock()
        let limiter = MCPRateLimiter(clock: clock)
        let authenticator = MCPBearerTokenAuthenticator(tokenStore: store, rateLimiter: limiter)

        for _ in 0..<5 {
            _ = await authenticator.authenticate(
                authorizationHeader: "Bearer wrong",
                clientAddress: .loopback
            )
        }

        let decision = await authenticator.authenticate(
            authorizationHeader: "Bearer \(plaintext)",
            clientAddress: .remote("10.0.0.1")
        )
        guard case .allow = decision else {
            Issue.record("Expected allow on different address, got \(decision)")
            return
        }
    }
}
