//
//  ExplainResultRouterTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("ExplainResultRouter planText")
struct ExplainResultRouterTests {
    @Test("Joins single-column explain rows with newlines")
    func joinsSingleColumnRows() {
        let rows: [[PluginCellValue]] = [[.text("-> Limit: 5 row(s)")], [.text("    -> Sort")]]
        let result = ExplainResultRouter.planText(sql: "EXPLAIN ANALYZE SELECT 1", columns: ["EXPLAIN"], rows: rows)
        #expect(result == "-> Limit: 5 row(s)\n    -> Sort")
    }

    @Test("Returns nil for multi-column explain results")
    func rejectsMultiColumn() {
        let rows: [[PluginCellValue]] = [[.text("1"), .text("SIMPLE")]]
        let result = ExplainResultRouter.planText(sql: "EXPLAIN SELECT 1", columns: ["id", "select_type"], rows: rows)
        #expect(result == nil)
    }

    @Test("Returns nil for non-explain statements")
    func rejectsNonExplain() {
        let rows: [[PluginCellValue]] = [[.text("value")]]
        let result = ExplainResultRouter.planText(sql: "SELECT col FROM t", columns: ["col"], rows: rows)
        #expect(result == nil)
    }

    @Test("Returns nil when the plan text is empty")
    func rejectsEmptyPlan() {
        #expect(ExplainResultRouter.planText(sql: "EXPLAIN SELECT 1", columns: ["EXPLAIN"], rows: []) == nil)
        let blank: [[PluginCellValue]] = [[.null]]
        #expect(ExplainResultRouter.planText(sql: "EXPLAIN SELECT 1", columns: ["EXPLAIN"], rows: blank) == nil)
    }
}
