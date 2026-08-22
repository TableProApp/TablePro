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
        ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN", format: .mysqlComposite),
        ExplainVariant(
            id: "explain-json",
            label: "EXPLAIN (JSON)",
            sqlPrefix: "EXPLAIN FORMAT=JSON",
            format: .mysqlComposite
        ),
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
        #expect(routed?.subjectSQL == "SELECT 1")
        #expect(routed?.format == .mysqlComposite)
        #expect(routed?.variantId?.hasPrefix("__typed_explain__:") == true)
        #expect(routed?.variantId != "explain")
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
        #expect(routed?.subjectSQL == "SELECT 1")
        #expect(routed?.format == .sqliteQueryPlan)
        #expect(routed?.variantId == "plan")
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

    @Test("Falls back to the exact SQL when no inner statement can be derived")
    func preservesExactSQLFallback() {
        let sql = "EXPLAIN VERBOSE"
        let routed = ExplainResultRouter.route(
            sql: sql,
            columns: ["EXPLAIN"],
            rows: [[.text("plan")]],
            databaseType: .mysql,
            declaredVariants: mysqlVariants
        )

        #expect(routed?.subjectSQL == sql)
    }

    @Test("Typed MySQL invocation preambles have separate history scopes")
    func scopesTypedMySQLInvocations() {
        let statements = [
            "EXPLAIN SELECT * FROM users",
            "EXPLAIN FORMAT=TREE SELECT * FROM users",
            "EXPLAIN ANALYZE SELECT * FROM users",
        ]
        let identifiers = statements.compactMap { sql in
            ExplainResultRouter.route(
                sql: sql,
                columns: ["EXPLAIN"],
                rows: [[.text("-> Table scan on users")]],
                databaseType: .mysql,
                declaredVariants: mysqlVariants
            )?.variantId
        }

        #expect(identifiers.count == 3)
        #expect(Set(identifiers).count == 3)
        #expect(identifiers[0] == "explain")
        #expect(identifiers[1].hasPrefix("__typed_explain__:"))
        #expect(identifiers[2].hasPrefix("__typed_explain__:"))
    }

    @Test("Typed history preambles normalize case and spacing")
    func normalizesTypedHistoryPreambles() {
        let compact = routeMySQL("EXPLAIN FORMAT=TREE SELECT * FROM users")
        let spaced = routeMySQL("  explain  format = tree  SELECT * FROM users")

        #expect(compact?.variantId == spaced?.variantId)
        #expect(compact?.subjectSQL == spaced?.subjectSQL)
    }

    @Test("Typed declared JSON keeps its variant identifier")
    func preservesDeclaredJSONVariant() {
        let routed = routeMySQL("EXPLAIN FORMAT=JSON SELECT * FROM users")

        #expect(routed?.variantId == "explain-json")
        #expect(routed?.format == .mysqlComposite)
        #expect(routed?.plan != nil)
    }

    @Test("Typed history discriminator is bounded and hides the preamble")
    func boundsTypedHistoryDiscriminator() throws {
        let sql = "EXPLAIN " + String(repeating: "OPTION ", count: 1_000) + "SELECT 1"
        let routed = try #require(routeMySQL(sql))
        let identifier = try #require(routed.variantId)

        #expect(identifier.hasPrefix("__typed_explain__:"))
        #expect(identifier.count == "__typed_explain__:".count + 64)
        #expect(!identifier.contains("OPTION"))
    }

    private func routeMySQL(_ sql: String) -> ExplainResultRouter.RoutedPlan? {
        ExplainResultRouter.route(
            sql: sql,
            columns: ["EXPLAIN"],
            rows: [[.text("-> Table scan on users")]],
            databaseType: .mysql,
            declaredVariants: mysqlVariants
        )
    }
}
