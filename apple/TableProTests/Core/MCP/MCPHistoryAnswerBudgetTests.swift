//
//  MCPHistoryAnswerBudgetTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

struct MCPHistoryAnswerBudgetTests {
    private let connectionId = UUID()

    private func entry(query: String, errorMessage: String? = nil) -> QueryHistoryEntry {
        QueryHistoryEntry(
            query: query,
            connectionId: connectionId,
            databaseName: "shop",
            databaseType: .postgresql,
            source: .editor,
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: errorMessage == nil,
            errorMessage: errorMessage
        )
    }

    @Test("A long statement or error in history is cut before it leaves the Mac")
    func longTextIsCut() {
        let statement = "INSERT INTO t VALUES " + String(repeating: "(1),", count: 50_000)
        let failure = "syntax error near " + String(repeating: "y", count: 200_000)

        let query = MCPConnectionBridge.externalQueryText(of: entry(query: statement), masksValues: false)
        let error = MCPConnectionBridge.externalErrorText(failure, masksValues: false)

        #expect(query.utf8.count < statement.utf8.count)
        #expect(query.hasPrefix(String(statement.prefix(1_000))))
        #expect(error.utf8.count < failure.utf8.count)
        // The redactor drops a token too long to read whole, since part of one can hold half a secret.
        #expect(error.hasPrefix("syntax error near"))
        #expect(!error.contains("yyy"))
    }

    @Test("Short history text passes through whole")
    func shortTextIsWhole() {
        #expect(MCPConnectionBridge.externalQueryText(of: entry(query: "SELECT 1"), masksValues: false) == "SELECT 1")
    }

    @Test("Entries stop at the answer budget, in order, and the answer says so")
    func entriesStopAtTheBudget() {
        let megabyte = String(repeating: "x", count: 1 << 20)
        let entries = (0..<6).map { index in JsonValue.object(["id": .int(index), "query": .string(megabyte)]) }

        let answer = MCPConnectionBridge.withinAnswerBudget(entries)
        let used = answer.entries.reduce(0) { $0 + $1.jsonString().utf8.count }

        #expect(answer.isTruncated)
        #expect(!answer.entries.isEmpty)
        #expect(answer.entries.count < entries.count)
        #expect(used <= ExternalAnswerBudget.answerBytes)
        #expect(answer.entries == Array(entries.prefix(answer.entries.count)))
    }

    @Test("An answer under the budget keeps every entry")
    func smallAnswerIsWhole() {
        let entries = (0..<3).map { index in JsonValue.object(["id": .int(index)]) }

        let answer = MCPConnectionBridge.withinAnswerBudget(entries)

        #expect(!answer.isTruncated)
        #expect(answer.entries == entries)
    }

    @Test("search_query_history reports is_truncated and cuts each statement")
    func searchReportsTruncation() async throws {
        let statement = String(repeating: "z", count: 200_000)
        let store = ToolTestQueryHistoryStore(entries: (0..<80).map { _ in entry(query: statement) })

        let result = try await SearchQueryHistoryTool().call(
            arguments: .object(["query": .string(""), "limit": .int(500)]),
            context: MCPToolTestHarness.context(principal: MCPToolTestHarness.principal(access: .all)),
            services: MCPToolTestHarness.services(
                authPolicy: MCPToolTestHarness.authPolicy(connections: [
                    connectionId: MCPToolTestHarness.snapshot(policy: .alwaysAllow)
                ]),
                history: store
            )
        )

        let payload = try #require(result.structuredContent)
        let entries = try #require(payload["entries"]?.arrayValue)
        #expect(payload["is_truncated"]?.boolValue == true)
        #expect(entries.count < 80)
        for entry in entries {
            #expect((entry["query"]?.stringValue?.utf8.count ?? 0) < statement.utf8.count)
        }
    }
}
