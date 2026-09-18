//
//  MCPServerDashboardPayloadTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("get_server_dashboard payload")
struct MCPServerDashboardPayloadTests {
    @Test("Panels that all read come back without an errors object")
    func noFailures() throws {
        let payload = try MCPConnectionBridge.dashboardPayload(
            panels: ["sessions": .array([]), "metrics": .array([])],
            failures: [:]
        )
        #expect(payload == .object(["sessions": .array([]), "metrics": .array([])]))
    }

    @Test("A panel that failed is reported under errors instead of as an empty list")
    func partialFailure() throws {
        let payload = try MCPConnectionBridge.dashboardPayload(
            panels: ["slow_queries": .array([])],
            failures: ["sessions": MCPConnectionBridge.dashboardPanelFailure(
                panel: "sessions", error: DatabaseAccessError.dataSourceError("column \"pid\" does not exist")
            )]
        )
        let errors = payload["errors"]?["sessions"]?.stringValue
        #expect(errors == "The server did not answer the sessions panel.")
        #expect(errors?.contains("pid") == false)
        #expect(payload["slow_queries"] == .array([]))
    }

    @Test("A panel failure never carries the server's own words to the client")
    func panelFailureIsFixedText() {
        let message = MCPConnectionBridge.dashboardPanelFailure(
            panel: "slow_queries",
            error: DatabaseAccessError.dataSourceError("permission denied for table secrets")
        )
        #expect(message == "The server did not answer the slow queries panel.")
        #expect(!message.contains("secrets"))
    }

    @Test("The output schema declares the errors object, one message per panel")
    func outputSchemaDeclaresErrors() {
        let errors = ServerDashboardTool.outputSchema?["properties"]?["errors"]?["properties"]
        for panel in ServerDashboardTool.panelNames {
            #expect(errors?[panel]?["type"]?.stringValue == "string")
        }
    }

    @Test("When every requested panel fails the call fails")
    func everyPanelFails() {
        #expect(throws: DatabaseAccessError.self) {
            _ = try MCPConnectionBridge.dashboardPayload(
                panels: [:],
                failures: ["sessions": "boom", "metrics": "bang"]
            )
        }
    }
}
