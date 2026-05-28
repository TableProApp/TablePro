import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("MCP Composite Authenticator")
struct MCPCompositeAuthenticatorTests {
    private func makeValidated(label: String = "test") -> MCPValidatedToken {
        MCPValidatedToken(
            tokenId: UUID(),
            label: label,
            scopes: [.toolsRead, .toolsWrite],
            issuedAt: Date(timeIntervalSince1970: 1_000_000),
            expiresAt: nil
        )
    }

    private func makeBearer(_ store: FakeMCPTokenStore) -> MCPBearerTokenAuthenticator {
        MCPBearerTokenAuthenticator(tokenStore: store, rateLimiter: MCPRateLimiter())
    }

    @Test("Loopback + auth disabled + no header allows anonymous")
    func loopbackAuthDisabledNoHeader() async {
        let store = FakeMCPTokenStore()
        let composite = MCPCompositeAuthenticator(bearer: makeBearer(store), requireAuthentication: false)
        let decision = await composite.authenticate(authorizationHeader: nil, clientAddress: .loopback)
        guard case .allow(let principal) = decision else {
            Issue.record("Expected allow, got \(decision)")
            return
        }
        #expect(principal.tokenId == nil)
        #expect(principal.tokenFingerprint == "anonymous-loopback")
        #expect(principal.scopes.contains(.toolsWrite))
        #expect(principal.scopes.contains(.admin))
    }

    @Test("Loopback + auth disabled + invalid bearer still allows anonymous")
    func loopbackAuthDisabledIgnoresBearer() async {
        let store = FakeMCPTokenStore()
        let composite = MCPCompositeAuthenticator(bearer: makeBearer(store), requireAuthentication: false)
        let decision = await composite.authenticate(
            authorizationHeader: "Bearer tp_invalidtoken",
            clientAddress: .loopback
        )
        guard case .allow(let principal) = decision else {
            Issue.record("Expected allow, got \(decision)")
            return
        }
        #expect(principal.tokenId == nil)
        #expect(principal.tokenFingerprint == "anonymous-loopback")
    }

    @Test("Loopback + auth required + valid bearer allows token principal")
    func loopbackAuthRequiredValidToken() async {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_realtoken"
        let validated = makeValidated(label: "Token A")
        await store.register(plaintext, validated: validated)
        let composite = MCPCompositeAuthenticator(bearer: makeBearer(store), requireAuthentication: true)
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
    }

    @Test("Loopback + auth required + missing header denies")
    func loopbackAuthRequiredMissingHeader() async {
        let store = FakeMCPTokenStore()
        let composite = MCPCompositeAuthenticator(bearer: makeBearer(store), requireAuthentication: true)
        let decision = await composite.authenticate(authorizationHeader: nil, clientAddress: .loopback)
        guard case .deny(let reason) = decision else {
            Issue.record("Expected deny, got \(decision)")
            return
        }
        #expect(reason.httpStatus == 401)
    }

    @Test("Remote + auth disabled still requires bearer")
    func remoteAuthDisabledStillRequiresBearer() async {
        let store = FakeMCPTokenStore()
        let composite = MCPCompositeAuthenticator(bearer: makeBearer(store), requireAuthentication: false)
        let decision = await composite.authenticate(
            authorizationHeader: nil,
            clientAddress: .remote("192.168.1.5")
        )
        guard case .deny(let reason) = decision else {
            Issue.record("Expected deny on remote even with auth disabled, got \(decision)")
            return
        }
        #expect(reason.httpStatus == 401)
    }

    @Test("Remote + auth required + valid bearer allows token principal")
    func remoteAuthRequiredValidToken() async {
        let store = FakeMCPTokenStore()
        let plaintext = "tp_remote_token"
        await store.register(plaintext, validated: makeValidated(label: "Remote Token"))
        let composite = MCPCompositeAuthenticator(bearer: makeBearer(store), requireAuthentication: true)
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
}
