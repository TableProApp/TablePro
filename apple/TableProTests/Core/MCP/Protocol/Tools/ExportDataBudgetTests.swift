//
//  ExportDataBudgetTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

@MainActor
struct ExportDataBudgetTests {
    nonisolated private static let wideValue = String(repeating: "w", count: 100_000)

    // `wide` holds values past 64 KiB, `big` alone passes 4 MiB, and `after` comes once the answer is spent.
    nonisolated private static func answer(_ query: String) -> QueryResult {
        if query.contains("\"wide\"") {
            return ScriptAnsweringDriver.resultSet(columns: ["doc"], rows: Array(repeating: [wideValue], count: 3))
        }
        if query.contains("\"big\"") {
            return ScriptAnsweringDriver.resultSet(
                columns: ["body"],
                rows: Array(repeating: [String(repeating: "x", count: 1_000)], count: 4_500)
            )
        }
        return ScriptAnsweringDriver.resultSet(columns: ["n"], rows: Array(repeating: ["1"], count: 5))
    }

    @Test("The tables of one export share one budget, and every value stays whole")
    func tablesShareOneBudget() async throws {
        let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
        let driver = ScriptAnsweringDriver(connection: connection, statementAnswer: Self.answer)
        var session = ConnectionSession(connection: connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let result = try await ExportDataTool().perform(
            arguments: .object([
                "connection_id": .string(connection.id.uuidString),
                "format": .string("csv"),
                "tables": .array([.string("wide"), .string("big"), .string("after")]),
                "max_rows": .int(5_000)
            ]),
            context: MCPToolTestHarness.context(),
            services: MCPToolTestHarness.services(
                authPolicy: MCPToolTestHarness.authPolicy(executionGate: AlwaysAllowGate()),
                settings: MCPSettings(defaultRowLimit: 500, maxRowLimit: 10_000)
            )
        )

        let payload = try #require(result.structuredContent)
        let exports = try #require(payload["exports"]?.arrayValue)
        try #require(exports.count == 3)
        #expect(exports[0]["row_count"]?.intValue == 3)
        #expect(exports[0]["is_truncated"]?.boolValue == false)
        let wide = try #require(exports[0]["data"]?.stringValue)
        #expect(wide.contains(Self.wideValue))
        #expect(!wide.contains("TablePro cut"))
        let bigRows = try #require(exports[1]["row_count"]?.intValue)
        #expect(bigRows > 0 && bigRows < 4_500)
        #expect((bigRows * 1_000) + (3 * 100_000) <= ExternalAnswerBudget.answerBytes)
        #expect(exports[1]["is_truncated"]?.boolValue == true)
        #expect(exports[2]["row_count"]?.intValue == 0)
        #expect(exports[2]["is_truncated"]?.boolValue == true)
        #expect(payload["is_truncated"]?.boolValue == true)
        #expect(payload["notes"]?.arrayValue?.count == 1)
    }
}
