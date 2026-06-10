import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("MCP Settings secure defaults")
struct MCPSettingsTests {
    @Test("Default settings require authentication")
    func defaultRequiresAuthentication() {
        #expect(MCPSettings.default.requireAuthentication)
        #expect(MCPSettings().requireAuthentication)
    }

    @Test("Settings JSON without the key decode to authentication required")
    func decodesAbsentKeyAsRequired() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(MCPSettings.self, from: json)
        #expect(decoded.requireAuthentication)
    }

    @Test("Explicit stored false is respected")
    func decodesExplicitValue() throws {
        let json = Data(#"{"requireAuthentication": false}"#.utf8)
        let decoded = try JSONDecoder().decode(MCPSettings.self, from: json)
        #expect(!decoded.requireAuthentication)
    }

    @Test("Default settings deny anonymous loopback without a token")
    func defaultDeniesAnonymousLoopback() async {
        let store = FakeMCPTokenStore()
        let bearer = MCPBearerTokenAuthenticator(tokenStore: store, rateLimiter: MCPRateLimiter())
        let composite = MCPCompositeAuthenticator(
            bearer: bearer,
            requireAuthentication: MCPSettings.default.requireAuthentication
        )
        let decision = await composite.authenticate(authorizationHeader: nil, clientAddress: .loopback)
        guard case .deny(let reason) = decision else {
            Issue.record("Expected deny for anonymous loopback under secure default, got \(decision)")
            return
        }
        #expect(reason.httpStatus == 401)
    }
}
