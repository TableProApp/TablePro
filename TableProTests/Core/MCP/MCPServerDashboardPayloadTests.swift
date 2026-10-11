//
//  MCPServerDashboardPayloadTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

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

struct MCPSessionControlStatementTests {
    private func provider(_ databaseType: DatabaseType) throws -> any ServerDashboardQueryProvider {
        try #require(ServerDashboardQueryProviderFactory.provider(for: databaseType))
    }

    private func refusal(
        _ databaseType: DatabaseType,
        processId: String,
        cancelOnly: Bool
    ) throws -> MCPToolExecutionError? {
        do {
            _ = try MCPConnectionBridge.sessionControlStatement(
                provider: try provider(databaseType),
                processId: processId,
                cancelOnly: cancelOnly
            )
            return nil
        } catch let error as DatabaseAccessError {
            return MCPToolExecutionError.from(error)
        }
    }

    @Test("A process id the engine cannot parse is an argument error that names it")
    func malformedProcessIdIsAnArgumentError() throws {
        let error = try #require(try refusal(.postgresql, processId: "abc", cancelOnly: true))
        #expect(error.code == .invalidArgument)
        #expect(error.message.contains("abc"))

        let clickHouse = try #require(try refusal(.clickhouse, processId: "abc", cancelOnly: false))
        #expect(clickHouse.code == .invalidArgument)
        #expect(clickHouse.message.contains("abc"))
    }

    @Test("Cancel on an engine that only kills names the mode that works")
    func cancelOnKillOnlyEngineNamesKill() throws {
        let mssql = try #require(try refusal(.mssql, processId: "52", cancelOnly: true))
        #expect(mssql.code == .invalidArgument)
        #expect(mssql.message.contains("kill"))

        let clickHouse = try #require(try refusal(
            .clickhouse,
            processId: "8f14e45f-ceea-467a-9575-8f0a1c3b2d4e",
            cancelOnly: true
        ))
        #expect(clickHouse.code == .invalidArgument)
        #expect(clickHouse.message.contains("kill"))
    }

    @Test("An engine with no session control keeps saying so")
    func engineWithoutSessionControl() throws {
        let error = try #require(try refusal(.duckdb, processId: "1", cancelOnly: true))
        #expect(error.code == .queryFailed)
        #expect(error.message == "This engine cannot stop a session from TablePro.")
    }

    @Test("A valid process id in a supported mode gives the engine's statement")
    func supportedModeBuildsTheStatement() throws {
        #expect(
            try MCPConnectionBridge.sessionControlStatement(
                provider: try provider(.postgresql), processId: "52", cancelOnly: true
            ) == "SELECT pg_cancel_backend(52)"
        )
        #expect(
            try MCPConnectionBridge.sessionControlStatement(
                provider: try provider(.mssql), processId: "52", cancelOnly: false
            ) == "KILL 52"
        )
    }

    @Test("No engine builds a statement for a process id it says it does not accept")
    func statementsAgreeWithTheProcessIdCheck() {
        let samples = ["52", "-1", "abc", "52; SELECT 1", "", "8f14e45f-ceea-467a-9575-8f0a1c3b2d4e"]
        for databaseType in DatabaseType.allKnownTypes {
            guard let provider = ServerDashboardQueryProviderFactory.provider(for: databaseType) else { continue }
            for processId in samples where !provider.acceptsProcessId(processId) {
                #expect(provider.killSessionSQL(processId: processId) == nil, "\(databaseType.rawValue) kill '\(processId)'")
                #expect(provider.cancelQuerySQL(processId: processId) == nil, "\(databaseType.rawValue) cancel '\(processId)'")
            }
        }
    }
}
