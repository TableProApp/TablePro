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

    @Test("Row limits decode to the documented defaults")
    func decodesRowLimitDefaults() throws {
        let decoded = try JSONDecoder().decode(MCPSettings.self, from: Data("{}".utf8))
        #expect(decoded.defaultRowLimit == 500)
        #expect(decoded.maxRowLimit == 10_000)
        #expect(decoded.queryTimeoutSeconds == 30)
    }

    @Test("A stored zero maximum row limit decodes to a usable value")
    func decodesZeroMaxRowLimit() throws {
        let json = Data(#"{"maxRowLimit": 0, "defaultRowLimit": 0, "queryTimeoutSeconds": 0}"#.utf8)
        let decoded = try JSONDecoder().decode(MCPSettings.self, from: json)
        #expect(decoded.maxRowLimit == 1)
        #expect(decoded.defaultRowLimit == 1)
        #expect(decoded.queryTimeoutSeconds == 1)
    }

    @Test("Stored negative limits decode to usable values")
    func decodesNegativeLimits() throws {
        let json = Data(#"{"maxRowLimit": -100, "defaultRowLimit": -5, "queryTimeoutSeconds": -1}"#.utf8)
        let decoded = try JSONDecoder().decode(MCPSettings.self, from: json)
        #expect(decoded.maxRowLimit == 1)
        #expect(decoded.defaultRowLimit == 1)
        #expect(decoded.queryTimeoutSeconds == 1)
    }

    @Test("A stored timeout above the protocol ceiling decodes clamped")
    func decodesTimeoutAboveCeiling() throws {
        let json = Data(#"{"queryTimeoutSeconds": 100000}"#.utf8)
        let decoded = try JSONDecoder().decode(MCPSettings.self, from: json)
        #expect(decoded.queryTimeoutSeconds == 300)
    }

    @Test("A default row limit above the maximum stays stored but resolves capped")
    func defaultAboveMaximumIsPreservedButCapped() throws {
        let json = Data(#"{"maxRowLimit": 1000, "defaultRowLimit": 50000}"#.utf8)
        let decoded = try JSONDecoder().decode(MCPSettings.self, from: json)
        #expect(decoded.defaultRowLimit == 50_000)
        #expect(decoded.effectiveDefaultRowLimit == 1_000)
    }

    @Test("The requestable row limit range is never inverted")
    func requestableRangeIsNeverInverted() {
        for maxRowLimit in [-1, 0, 1, 10_000, 10_000_000] {
            let range = MCPSettings(maxRowLimit: maxRowLimit).requestableRowLimitRange
            #expect(range.lowerBound <= range.upperBound)
        }
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
