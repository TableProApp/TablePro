//
//  MCPScriptResultTests.swift
//  TableProTests
//
//  execute_query, and the assistant's tool of the same name, answer a SQL Server script with every result set it
//  returned. The fields a client already reads keep describing one result, the first, so a client that knows nothing
//  of scripts reads what it always read (#3078).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private actor DiscardingHistory: QueryHistoryRecording {
    func record(_ request: QueryHistoryRecordRequest) async -> Bool { true }
}

@Suite("MCP answers a SQL Server script with every result set", .serialized)
@MainActor
struct MCPScriptResultTests {
    private let scope = DatabaseScope(connectionId: UUID(), database: "warehouse", schema: "dbo")

    private func scriptOutcome(
        _ resultSets: [QueryResult],
        rowsAffected: Int = 0,
        sessionState: PluginSessionTransactionState = .idle
    ) -> DatabaseAccessBridge.ScriptOutcome {
        ScriptBatchRun(
            answers: [ScriptAnsweringDriver.batch(resultSets, rowsAffected: rowsAffected)],
            sessionState: sessionState
        ).outcome(executionTimeMs: 12)
    }

    @Test("The top-level fields are the first result set, and result_sets lists every one of them")
    func scriptListsEveryResultSet() throws {
        let outcome = scriptOutcome(
            [
                ScriptAnsweringDriver.resultSet(columns: ["a"], rows: [["1"]]),
                ScriptAnsweringDriver.resultSet(columns: ["b", "c"], rows: [["x", "y"], ["z", "w"]], isTruncated: true)
            ],
            rowsAffected: 5
        )

        let payload = MCPConnectionBridge.encode(script: outcome, scope: scope)

        #expect(payload["columns"]?.arrayValue?.compactMap(\.stringValue) == ["a"])
        #expect(payload["row_count"]?.intValue == 1)
        #expect(payload["rows_affected"]?.intValue == 5)
        #expect(payload["is_truncated"]?.boolValue == false)
        #expect(payload["database"]?.stringValue == "warehouse")
        #expect(payload["status_message"] == nil)
        let resultSets = try #require(payload["result_sets"]?.arrayValue)
        #expect(resultSets.map { $0["columns"]?.arrayValue?.compactMap(\.stringValue) } == [["a"], ["b", "c"]])
        #expect(resultSets.map { $0["row_count"]?.intValue } == [1, 2])
        #expect(resultSets.map { $0["is_truncated"]?.boolValue } == [false, true])
        #expect(resultSets[1]["rows"]?.arrayValue?.first?.arrayValue?.compactMap(\.stringValue) == ["x", "y"])
    }

    @Test("A single result carries no result_sets, so the payload is the one a statement always had")
    func singleResultKeepsTheStatementShape() {
        let result = ScriptAnsweringDriver.resultSet(columns: ["n"], rows: [["1"]])

        let payload = MCPConnectionBridge.encode(script: .statement(result, executionTimeMs: 3), scope: scope)

        #expect(payload["result_sets"] == nil)
        #expect(payload == MCPConnectionBridge.encode(result: result, scope: scope, executionTimeMs: 3))
    }

    @Test("A script that leaves a transaction open says so in status_message")
    func openTransactionIsReported() throws {
        let notice = try #require(PluginSessionTransactionState.inTransaction.openTransactionNotice)

        let payload = MCPConnectionBridge.encode(
            script: scriptOutcome([], rowsAffected: 2, sessionState: .inTransaction),
            scope: scope
        )

        #expect(payload["status_message"]?.stringValue == notice)
        #expect(payload["rows_affected"]?.intValue == 2)
        #expect(payload["columns"]?.arrayValue?.isEmpty == true)
    }

    @Test("execute_query declares result_sets in its output schema and keeps the fields it required")
    func outputSchemaDeclaresResultSets() {
        let schema = ExecuteQueryTool.outputSchema
        #expect(schema?["properties"]?["result_sets"]?["items"]?["properties"]?["columns"] != nil)
        #expect(schema?["required"] == MCPToolSchema.resultSet["required"])
        #expect(MCPToolSchema.resultSet["properties"]?["result_sets"] == nil)
    }

    @Test("The query executor runs a script and answers with every result set")
    func executorRunsTheTextAsAScript() async throws {
        let driver = ScriptAnsweringDriver(
            connection: TestFixtures.makeConnection(database: "warehouse", type: .mssql)
        ) { _ in
            ScriptAnsweringDriver.batch([
                ScriptAnsweringDriver.resultSet(columns: ["a"], rows: [["1"]]),
                ScriptAnsweringDriver.resultSet(columns: ["b"], rows: [["2"], ["3"]])
            ])
        }
        var session = ConnectionSession(connection: driver.connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: driver.connection.id)
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy(
                connectionResolver: { _ in nil },
                connectionIdsProvider: { [] },
                historyRecorder: DiscardingHistory()
            )
        )

        let payload = try await ToolQueryExecutor.executeAndLog(
            services: services,
            query: "DECLARE @n INT = 1;\nSELECT @n AS a;\nSELECT 2 AS b",
            scope: DatabaseScope(connectionId: driver.connection.id, database: "warehouse", schema: nil),
            maxRows: 10,
            timeoutSeconds: 30,
            principal: MCPToolTestHarness.principal(),
            unit: .script
        )

        #expect(driver.sentBatches.map(\.rowCap) == [10])
        #expect(payload["result_sets"]?.arrayValue?.count == 2)
        #expect(payload["columns"]?.arrayValue?.compactMap(\.stringValue) == ["a"])
    }
}
