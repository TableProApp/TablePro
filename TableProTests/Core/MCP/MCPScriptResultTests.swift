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

    // MARK: - Through every gate

    nonisolated private static let scripts = [
        "SELECT 1 AS a;\nSELECT 2 AS b;",
        "SELECT 1 AS a\nGO\nSELECT 2 AS b"
    ]

    /// A SQL Server session at Silent, whose driver answers each batch with one result set per `AS` alias it holds.
    private func sqlServerSession() -> ScriptAnsweringDriver {
        var connection = TestFixtures.makeConnection(database: "warehouse", type: .mssql)
        connection.aiPolicy = .alwaysAllow
        let driver = ScriptAnsweringDriver(connection: connection) { batch in
            ScriptAnsweringDriver.batch(
                ["a", "b"].filter { batch.contains("AS \($0)") }.map { alias in
                    ScriptAnsweringDriver.resultSet(columns: [alias], rows: [["1"]])
                }
            )
        }
        var session = ConnectionSession(connection: connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return driver
    }

    private func authPolicy() -> MCPAuthPolicy {
        MCPAuthPolicy(connectionResolver: { _ in nil }, connectionIdsProvider: { [] }, historyRecorder: DiscardingHistory())
    }

    @Test("execute_query runs a SQL Server script of several statements past both gates", arguments: scripts)
    func executeQueryToolRunsTheScript(script: String) async throws {
        let driver = sqlServerSession()
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        let result = try await ExecuteQueryTool().perform(
            arguments: .object([
                "connection_id": .string(driver.connection.id.uuidString),
                "query": .string(script)
            ]),
            context: MCPToolTestHarness.context(),
            services: MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: authPolicy())
        )

        let payload = try #require(result.structuredContent)
        #expect(!result.isError)
        #expect(payload["result_sets"]?.arrayValue?.map { $0["columns"]?.arrayValue?.compactMap(\.stringValue) }
            == [["a"], ["b"]])
        #expect(!driver.sentBatches.isEmpty)
    }

    @Test("The assistant's execute_query runs a SQL Server script of several statements past both gates", arguments: scripts)
    func chatToolRunsTheScript(script: String) async throws {
        let driver = sqlServerSession()
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }
        let context = ChatToolContext(
            connectionId: driver.connection.id,
            bridge: MCPConnectionBridge(),
            authPolicy: authPolicy()
        )

        let result = try await ExecuteQueryChatTool().execute(input: .object(["query": .string(script)]), context: context)

        #expect(!result.isError)
        let payload = try JSONDecoder().decode(JsonValue.self, from: Data(result.content.utf8))
        #expect(payload["result_sets"]?.arrayValue?.count == 2)
        #expect(!driver.sentBatches.isEmpty)
    }

    /// Measured on Azure SQL Edge 15: `GO\nDROP TABLE dbo.stale` sent whole answers Msg 2812, "Could not find stored
    /// procedure 'GO'", and still drops the table, so the tool reports a failure for a statement that ran.
    @Test("A GO line ahead of the one statement a tool sends never reaches the driver")
    func leadingSeparatorIsNotSent() async throws {
        let driver = sqlServerSession()
        defer { DatabaseManager.shared.removeSession(for: driver.connection.id) }

        _ = try await ToolQueryExecutor.executeAndLog(
            services: MCPToolServices(connectionBridge: MCPConnectionBridge(), authPolicy: authPolicy()),
            query: "GO\nDROP TABLE dbo.stale",
            scope: DatabaseScope(connectionId: driver.connection.id, database: "warehouse", schema: nil),
            maxRows: 0,
            timeoutSeconds: 30,
            principal: MCPToolTestHarness.principal()
        )

        #expect(driver.sentStatements == ["DROP TABLE dbo.stale"])
        #expect(driver.sentBatches.isEmpty)
    }
}
