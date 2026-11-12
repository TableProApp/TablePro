//
//  MCPAnswerBudgetPayloadTests.swift
//  TableProTests
//
//  An answer the size limit cut tells the client so: is_truncated stays the flag it reads, and notes say why.
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

@MainActor
struct MCPAnswerBudgetPayloadTests {
    private let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: nil)

    private func textResult(_ values: [String]) -> QueryResult {
        ScriptAnsweringDriver.resultSet(columns: ["body"], rows: values.map { [$0] })
    }

    @Test("An answer with a cut value and rows left out carries both notes and is_truncated")
    func cutAnswerCarriesNotes() throws {
        var budget = ExternalAnswerBudget(bytes: 70_000)
        let kept = budget.keep(textResult([String(repeating: "a", count: 100_000), String(repeating: "b", count: 10_000)]))

        let payload = MCPConnectionBridge.encode(
            script: .statement(kept, executionTimeMs: 1, budget: budget),
            scope: scope
        )

        #expect(payload["row_count"]?.intValue == 1)
        #expect(payload["is_truncated"]?.boolValue == true)
        #expect(payload["notes"]?.arrayValue?.compactMap { $0.stringValue } == budget.notes)
        #expect(budget.notes.count == 2)
    }

    @Test("An answer that fit carries no notes")
    func fittingAnswerHasNoNotes() {
        var budget = ExternalAnswerBudget.mcpAnswer
        let kept = budget.keep(textResult(["1", "2"]))

        let payload = MCPConnectionBridge.encode(script: .statement(kept, executionTimeMs: 1, budget: budget), scope: scope)

        #expect(payload["notes"] == nil)
        #expect(payload["is_truncated"]?.boolValue == false)
    }

    @Test("execute_query through the bridge holds a large read to 4 MiB and says so")
    func executeQueryIsHeldToTheBudget() async throws {
        let driver = AnsweringPluginDriver { _ in
            AnsweringPluginDriver.textRows(column: "body", count: 3_000, bytes: 2_048)
        }
        let scope = AnsweringPluginDriver.install(driver, connection: TestFixtures.makeConnection(database: "shop", type: .postgresql))
        defer { DatabaseManager.shared.removeSession(for: scope.connectionId) }

        let payload = try await MCPConnectionBridge().executeQuery(
            scope: scope, query: "SELECT body FROM documents", maxRows: 3_000, timeoutSeconds: 30, cancellation: nil
        )

        let rowCount = try #require(payload["row_count"]?.intValue)
        #expect(rowCount < 3_000)
        #expect(rowCount * 2_048 <= ExternalAnswerBudget.answerBytes)
        #expect(payload["rows"]?.arrayValue?.count == rowCount)
        #expect(payload["is_truncated"]?.boolValue == true)
        #expect(payload["notes"]?.arrayValue?.count == 1)
    }

    @Test("The assistant's execute_query holds its answer to 256 KiB")
    func assistantAnswerIsSmaller() async throws {
        let driver = AnsweringPluginDriver { _ in
            AnsweringPluginDriver.textRows(column: "body", count: 500, bytes: 2_048)
        }
        let scope = AnsweringPluginDriver.install(driver, connection: TestFixtures.makeConnection(database: "shop", type: .postgresql))
        defer { DatabaseManager.shared.removeSession(for: scope.connectionId) }
        let context = ChatToolContext(
            connectionId: scope.connectionId,
            bridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy(
                connectionResolver: { _ in nil },
                connectionIdsProvider: { [] },
                historyRecorder: RecordingQueryHistory(),
                executionGate: AlwaysAllowGate()
            ),
            policyLookup: { _ in .alwaysAllow }
        )

        let result = try await ExecuteQueryChatTool().execute(
            input: .object(["query": .string("SELECT body FROM documents"), "max_rows": .int(500)]),
            context: context
        )

        #expect(!result.isError)
        let payload = try JSONDecoder().decode(JsonValue.self, from: Data(result.content.utf8))
        let rowCount = try #require(payload["row_count"]?.intValue)
        #expect(rowCount > 0)
        #expect(rowCount * 2_048 <= ExternalAnswerBudget.assistantAnswerBytes)
        #expect(payload["is_truncated"]?.boolValue == true)
        #expect(driver.sent.first?.context.resultByteLimit == ExternalAnswerBudget.assistantAnswerBytes)
    }

    private func explain(planFilter filter: String) async throws -> JsonValue {
        let plan = #"[{"Plan": {"Node Type": "Seq Scan", "Relation Name": "orders", "Filter": "\#(filter)"}}]"#
        let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
        let driver = ScriptAnsweringDriver(connection: connection, statementAnswer: { _ in
            ScriptAnsweringDriver.resultSet(columns: ["QUERY PLAN"], rows: [[plan]])
        })
        var session = ConnectionSession(connection: connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)
        let request = try MCPConnectionBridge.explainRequest(
            for: "SELECT * FROM orders",
            databaseType: .postgresql,
            variants: [ExplainVariant(id: "json", label: "JSON", sqlPrefix: "EXPLAIN (FORMAT JSON)", format: .postgresJson)],
            variantId: nil,
            analyze: false
        )
        let operation = try await ApprovedOperationFixture.approve(
            [OperationStatement(sql: request.statement)], scope: scope, databaseType: .postgresql
        )
        return try await MCPConnectionBridge().explainQuery(
            operation, request: request, timeoutSeconds: 30, cancellation: nil
        )
    }

    @Test("explain_query leaves out a parsed plan past the budget, so the answer stays under 4 MiB")
    func explainPlanIsHeldToTheBudget() async throws {
        let payload = try await explain(planFilter: String(repeating: "f", count: 3_000_000))

        #expect(payload["plan"] == nil)
        #expect((payload["plan_text"]?.stringValue?.utf8.count ?? 0) >= 3_000_000)
        #expect(payload["is_truncated"]?.boolValue == true)
        #expect(payload["notes"]?.arrayValue?.isEmpty == false)
        #expect(payload.jsonString(prettyPrinted: false).utf8.count <= ExternalAnswerBudget.answerBytes)
    }

    @Test("explain_query keeps a parsed plan that fits")
    func explainPlanThatFitsIsKept() async throws {
        let payload = try await explain(planFilter: "(id > 1)")

        #expect(payload["plan"]?["root"]?["operation"]?.stringValue == "Seq Scan")
        #expect(payload["is_truncated"] == nil)
        #expect(payload["notes"] == nil)
    }

    @Test("The result schemas declare notes and keep the fields they required")
    func schemasDeclareNotes() {
        let executeQuery = ExecuteQueryTool.outputSchema
        #expect(executeQuery?["properties"]?["notes"]?["type"]?.stringValue == "array")
        #expect(executeQuery?["required"] == MCPToolSchema.resultSet["required"])
        #expect(executeQuery?["properties"]?["result_sets"]?["items"]?["properties"]?["notes"] == nil)
        #expect(MCPToolSchema.resultSet["properties"]?["notes"] != nil)
        #expect(ExportDataTool.outputSchema?["properties"]?["notes"] != nil)
        #expect(ExplainQueryTool.outputSchema?["properties"]?["notes"] != nil)
        #expect(ExplainQueryTool.outputSchema?["properties"]?["is_truncated"] != nil)
    }
}
