//
//  ExplainResultRouterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("ExplainResultRouter planText")
struct ExplainResultRouterTests {
    private let sqliteVariants = [
        ExplainVariant(
            id: "plan", label: "Query Plan", sqlPrefix: "EXPLAIN QUERY PLAN", format: .sqliteQueryPlan
        )
    ]

    private let mysqlVariants = [
        ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN", format: .mysqlComposite)
    ]

    @Test("Joins single-column explain rows with newlines")
    func joinsSingleColumnRows() {
        let rows: [[PluginCellValue]] = [[.text("-> Limit: 5 row(s)")], [.text("    -> Sort")]]
        let result = ExplainResultRouter.planText(
            sql: "EXPLAIN ANALYZE SELECT 1", columns: ["EXPLAIN"], rows: rows, declaredVariants: []
        )
        #expect(result == "-> Limit: 5 row(s)\n    -> Sort")
    }

    @Test("Returns nil for a multi-column result no variant declares")
    func rejectsUndeclaredMultiColumn() {
        let rows: [[PluginCellValue]] = [[.text("1"), .text("SIMPLE")]]
        let result = ExplainResultRouter.planText(
            sql: "ANALYZE TABLE users", columns: ["Table", "Op"], rows: rows, declaredVariants: mysqlVariants
        )
        #expect(result == nil)
    }

    @Test("A multi-column plan from a declared variant still routes to the viewer")
    func acceptsDeclaredMultiColumn() {
        let rows: [[PluginCellValue]] = [[.text("2"), .text("0"), .text("0"), .text("SCAN users")]]
        let result = ExplainResultRouter.planText(
            sql: "EXPLAIN QUERY PLAN SELECT 1",
            columns: ["id", "parent", "notused", "detail"],
            rows: rows,
            declaredVariants: sqliteVariants
        )
        #expect(result == "2\t0\t0\tSCAN users")
    }

    @Test("Returns nil for non-explain statements")
    func rejectsNonExplain() {
        let rows: [[PluginCellValue]] = [[.text("value")]]
        let result = ExplainResultRouter.planText(
            sql: "SELECT col FROM t", columns: ["col"], rows: rows, declaredVariants: []
        )
        #expect(result == nil)
    }

    @Test("Returns nil when the plan text is empty")
    func rejectsEmptyPlan() {
        #expect(
            ExplainResultRouter.planText(
                sql: "EXPLAIN SELECT 1", columns: ["EXPLAIN"], rows: [], declaredVariants: []
            ) == nil
        )
        let blank: [[PluginCellValue]] = [[.null]]
        #expect(
            ExplainResultRouter.planText(
                sql: "EXPLAIN SELECT 1", columns: ["EXPLAIN"], rows: blank, declaredVariants: []
            ) == nil
        )
    }
}
