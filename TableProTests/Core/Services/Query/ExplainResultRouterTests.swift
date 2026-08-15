//
//  ExplainResultRouterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("ExplainResultRouter")
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
        let routed = ExplainResultRouter.route(
            sql: "EXPLAIN ANALYZE SELECT 1",
            columns: ["EXPLAIN"],
            rows: rows,
            databaseType: .mysql,
            declaredVariants: mysqlVariants
        )
        #expect(routed?.rawText == "-> Limit: 5 row(s)\n    -> Sort")
    }

    @Test("A multi-column plan the app can read routes to the viewer")
    func acceptsParsableMultiColumn() {
        let rows: [[PluginCellValue]] = [[.text("2"), .text("0"), .text("0"), .text("SCAN users")]]
        let routed = ExplainResultRouter.route(
            sql: "EXPLAIN QUERY PLAN SELECT 1",
            columns: ["id", "parent", "notused", "detail"],
            rows: rows,
            databaseType: .sqlite,
            declaredVariants: sqliteVariants
        )
        #expect(routed?.rawText == "2\t0\t0\tSCAN users")
        #expect(routed?.plan != nil)
    }

    /// MySQL declares an `EXPLAIN` variant, so prefix matching alone would drag its tabular
    /// EXPLAIN into the plan viewer. Requiring a parse keeps it in the grid.
    @Test("MySQL's tabular EXPLAIN stays in the results grid")
    func rejectsTabularMySQLExplain() {
        let rows: [[PluginCellValue]] = [
            [.text("1"), .text("SIMPLE"), .text("users"), .text("ALL"), .text("10")]
        ]
        let routed = ExplainResultRouter.route(
            sql: "EXPLAIN SELECT * FROM users",
            columns: ["id", "select_type", "table", "type", "rows"],
            rows: rows,
            databaseType: .mysql,
            declaredVariants: mysqlVariants
        )
        #expect(routed == nil)
    }

    @Test("A maintenance ANALYZE is not a plan")
    func rejectsMaintenanceAnalyze() {
        let rows: [[PluginCellValue]] = [[.text("db.users"), .text("analyze"), .text("status"), .text("OK")]]
        let routed = ExplainResultRouter.route(
            sql: "ANALYZE TABLE users",
            columns: ["Table", "Op", "Msg_type", "Msg_text"],
            rows: rows,
            databaseType: .mysql,
            declaredVariants: mysqlVariants
        )
        #expect(routed == nil)
    }

    @Test("Returns nil for non-explain statements")
    func rejectsNonExplain() {
        let rows: [[PluginCellValue]] = [[.text("value")]]
        let routed = ExplainResultRouter.route(
            sql: "SELECT col FROM t",
            columns: ["col"],
            rows: rows,
            databaseType: .mysql,
            declaredVariants: mysqlVariants
        )
        #expect(routed == nil)
    }

    @Test("Returns nil when the plan text is empty")
    func rejectsEmptyPlan() {
        #expect(
            ExplainResultRouter.route(
                sql: "EXPLAIN SELECT 1",
                columns: ["EXPLAIN"],
                rows: [],
                databaseType: .mysql,
                declaredVariants: mysqlVariants
            ) == nil
        )
        let blank: [[PluginCellValue]] = [[.null]]
        #expect(
            ExplainResultRouter.route(
                sql: "EXPLAIN SELECT 1",
                columns: ["EXPLAIN"],
                rows: blank,
                databaseType: .mysql,
                declaredVariants: mysqlVariants
            ) == nil
        )
    }
}
