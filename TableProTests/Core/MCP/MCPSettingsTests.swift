import Foundation
@testable import TablePro
import Testing

struct MCPSettingsTests {
    @Test("The server is off until the user turns it on")
    func defaultIsDisabled() {
        #expect(!MCPSettings.default.enabled)
        #expect(!MCPSettings().enabled)
        let decoded = try? JSONDecoder().decode(MCPSettings.self, from: Data("{}".utf8))
        #expect(decoded?.enabled == false)
    }

    @Test("Listing connections hidden from AI is off until the user turns it on")
    func hiddenConnectionListingIsOffByDefault() throws {
        #expect(!MCPSettings.default.allowsHiddenConnectionListing)
        #expect(!MCPSettings().allowsHiddenConnectionListing)
        let absent = try JSONDecoder().decode(MCPSettings.self, from: Data("{}".utf8))
        #expect(!absent.allowsHiddenConnectionListing)
        let stored = try JSONDecoder().decode(
            MCPSettings.self,
            from: Data(#"{"allowsHiddenConnectionListing": true}"#.utf8)
        )
        #expect(stored.allowsHiddenConnectionListing)
    }

    @Test("The settings carry no remote-access or authentication switch")
    func thereIsNoRemoteAccessSwitch() throws {
        let json = Data(#"{"allowRemoteConnections": true, "requireAuthentication": false}"#.utf8)
        let decoded = try JSONDecoder().decode(MCPSettings.self, from: json)
        let reencoded = try JSONEncoder().encode(decoded)
        let fields = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any] ?? [:]

        #expect(Set(fields.keys) == [
            "enabled",
            "port",
            "defaultRowLimit",
            "maxRowLimit",
            "queryTimeoutSeconds",
            "logQueriesInHistory",
            "connectionApproval",
            "allowsHiddenConnectionListing"
        ])
        #expect(decoded == MCPSettings.default)
    }

    @Test("Nothing in the settings names a host or an interface to bind")
    func thereIsNoBindAddressSetting() throws {
        let encoded = try JSONEncoder().encode(MCPSettings.default)
        let fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]

        for banned in ["allowRemoteConnections", "host", "bindAddress", "tls", "useTLS", "certificatePath"] {
            #expect(fields[banned] == nil)
        }
    }

    @Test("Connection approval defaults to asking once for each connection")
    func defaultApprovalAsksOnce() throws {
        #expect(MCPSettings.default.connectionApproval == .oncePerConnection)
        #expect(MCPSettings().connectionApproval == .oncePerConnection)
        let decoded = try JSONDecoder().decode(MCPSettings.self, from: Data("{}".utf8))
        #expect(decoded.connectionApproval == .oncePerConnection)
    }

    @Test("A settings blob written before the approval setting existed keeps asking")
    func decodesLegacyBlobAsAsking() throws {
        let json = Data(#"{"enabled": true}"#.utf8)
        let decoded = try JSONDecoder().decode(MCPSettings.self, from: json)
        #expect(decoded.connectionApproval == .oncePerConnection)
        #expect(decoded.connectionApproval.asksBeforeReachingAConnection)
    }

    @Test("Each stored approval level round trips")
    func decodesEachApprovalLevel() throws {
        for level in MCPConnectionApproval.allCases {
            let json = Data(#"{"connectionApproval": "\#(level.rawValue)"}"#.utf8)
            let decoded = try JSONDecoder().decode(MCPSettings.self, from: json)
            #expect(decoded.connectionApproval == level)
        }
    }

    @Test("Only the permissive level stops asking, and only it forgets the answer")
    func approvalLevelSemantics() {
        #expect(MCPConnectionApproval.everyTime.asksBeforeReachingAConnection)
        #expect(MCPConnectionApproval.oncePerConnection.asksBeforeReachingAConnection)
        #expect(!MCPConnectionApproval.alwaysApprove.asksBeforeReachingAConnection)

        #expect(!MCPConnectionApproval.everyTime.remembersAnswer)
        #expect(MCPConnectionApproval.oncePerConnection.remembersAnswer)
        #expect(!MCPConnectionApproval.alwaysApprove.remembersAnswer)
    }

    @Test("A stored port outside the valid range falls back to the default")
    func decodesAnOutOfRangePort() throws {
        for stored in ["0", "-1", "70000"] {
            let json = Data(#"{"port": \#(stored)}"#.utf8)
            let decoded = try JSONDecoder().decode(MCPSettings.self, from: json)
            #expect(decoded.port == 23_508)
        }
    }

    @Test("A stored port inside the valid range is kept")
    func decodesAnInRangePort() throws {
        let json = Data(#"{"port": 5000}"#.utf8)
        let decoded = try JSONDecoder().decode(MCPSettings.self, from: json)
        #expect(decoded.port == 5_000)
    }

    @Test("Row limits decode to the documented defaults")
    func decodesRowLimitDefaults() throws {
        let decoded = try JSONDecoder().decode(MCPSettings.self, from: Data("{}".utf8))
        #expect(decoded.defaultRowLimit == 500)
        #expect(decoded.maxRowLimit == 10_000)
        #expect(decoded.queryTimeoutSeconds == 30)
        #expect(decoded.logQueriesInHistory)
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

    @Test("Settings survive a full encode and decode round trip")
    func settingsRoundTrip() throws {
        let original = MCPSettings(
            enabled: true,
            port: 5_000,
            defaultRowLimit: 250,
            maxRowLimit: 2_000,
            queryTimeoutSeconds: 45,
            logQueriesInHistory: false
        )

        let decoded = try JSONDecoder().decode(MCPSettings.self, from: try JSONEncoder().encode(original))

        #expect(decoded == original)
    }
}
