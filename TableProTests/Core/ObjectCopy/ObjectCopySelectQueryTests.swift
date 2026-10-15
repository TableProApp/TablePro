//
//  ObjectCopySelectQueryTests.swift
//  TableProTests
//
//  The read side of a copy names its columns, in the order the INSERT will
//  write them, so the stream and the statement cannot drift apart.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class QuotingDriver: PluginDriverStub, @unchecked Sendable {
    private let injectsRowLimit: Bool

    init(injectsRowLimit: Bool = true) {
        self.injectsRowLimit = injectsRowLimit
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }
    func injectRowLimit(_ query: String, limit: Int) -> String? {
        injectsRowLimit ? "\(query) LIMIT \(limit)" : nil
    }
}

struct ObjectCopySelectQueryTests {
    private let driver = QuotingDriver()

    @Test
    func columnsAreNamedAndQuotedInOrder() {
        #expect(ObjectCopySelectQuery.build(
                columns: ["id", "total"], table: "orders", schema: "public", driver: driver,
                databaseType: .postgresql
            ) == "SELECT \"id\", \"total\" FROM \"public\".\"orders\"")
    }

    @Test
    func anUnqualifiedTableKeepsThePlainName() {
        #expect(ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: nil, driver: driver, databaseType: .postgresql
            ) == "SELECT \"id\" FROM \"orders\"")
    }

    @Test
    func anEmptySchemaIsTreatedAsNoSchema() {
        #expect(ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: "", driver: driver, databaseType: .postgresql
            ) == "SELECT \"id\" FROM \"orders\"")
    }

    @Test
    func theEngineImplicitSchemaIsLeftUnqualified() {
        #expect(ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: "(default)", driver: driver, databaseType: .spanner
            ) == "SELECT \"id\" FROM \"orders\"")
        #expect(ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: "sales", driver: driver, databaseType: .spanner
            ) == "SELECT \"id\" FROM \"sales\".\"orders\"")
    }

    /// A structure-only step has no columns, and a star select is the honest fallback rather than
    /// a `SELECT  FROM`.
    @Test
    func noColumnsFallsBackToStar() {
        #expect(ObjectCopySelectQuery.build(
                columns: [], table: "orders", schema: nil, driver: driver, databaseType: .postgresql
            ) == "SELECT * FROM \"orders\"")
    }

    // MARK: - Row scope

    @Test
    func aFilterBecomesAWhereClause() {
        #expect(ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: nil, driver: driver, databaseType: .postgresql,
                scope: PluginExportRowScope(filter: "total > 10")
            ) == "SELECT \"id\" FROM \"orders\" WHERE total > 10")
    }

    /// Through the driver's own injection, because `LIMIT` is not the spelling on SQL Server or on
    /// Oracle before 12c.
    @Test
    func aRowLimitGoesThroughTheDriver() {
        #expect(ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: nil, driver: driver, databaseType: .postgresql,
                scope: PluginExportRowScope(filter: "total > 10", rowLimit: 50)
            ) == "SELECT \"id\" FROM \"orders\" WHERE total > 10 LIMIT 50")
    }

    @Test
    func aRowLimitTheDriverCannotInjectIsSpelledForSQLServer() {
        #expect(ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: "dbo", driver: QuotingDriver(injectsRowLimit: false),
                databaseType: .mssql, scope: PluginExportRowScope(filter: "total > 10", rowLimit: 10)
            ) == "SELECT TOP 10 \"id\" FROM \"dbo\".\"orders\" WHERE total > 10")
    }

    @Test
    func aRowLimitTheDriverCannotInjectIsSpelledForOracle() {
        #expect(ObjectCopySelectQuery.build(
                columns: ["ID"], table: "ORDERS", schema: "HR", driver: QuotingDriver(injectsRowLimit: false),
                databaseType: .oracle, scope: PluginExportRowScope(filter: "TOTAL > 10", rowLimit: 10)
            ) == "SELECT \"ID\" FROM \"HR\".\"ORDERS\" WHERE TOTAL > 10 FETCH FIRST 10 ROWS ONLY")
    }

    @Test
    func aRowLimitTheDriverCannotInjectIsSpelledForDamengWithoutSorting() {
        #expect(ObjectCopySelectQuery.build(
                columns: ["DOC"], table: "ORDERS", schema: "SYSDBA", driver: QuotingDriver(injectsRowLimit: false),
                databaseType: .dameng, scope: PluginExportRowScope(rowLimit: 10)
            ) == "SELECT \"DOC\" FROM \"SYSDBA\".\"ORDERS\" FETCH FIRST 10 ROWS ONLY")
    }

    @Test
    func aRowLimitTheDriverCannotInjectStaysLimitOnTrino() {
        #expect(ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: "sales", driver: QuotingDriver(injectsRowLimit: false),
                databaseType: .trino, scope: PluginExportRowScope(rowLimit: 10)
            ) == "SELECT \"id\" FROM \"sales\".\"orders\" LIMIT 10")
    }

    @Test
    func aRowLimitTheDriverCannotInjectIsSpelledForTeradata() {
        #expect(ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: "sales", driver: QuotingDriver(injectsRowLimit: false),
                databaseType: .teradata, scope: PluginExportRowScope(rowLimit: 10)
            ) == "SELECT TOP 10 \"id\" FROM \"sales\".\"orders\"")
    }

    @Test
    func aRowLimitTheDriverCannotInjectStaysLimitOnMySQL() {
        #expect(ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: nil, driver: QuotingDriver(injectsRowLimit: false),
                databaseType: .mysql, scope: PluginExportRowScope(filter: "total > 10", rowLimit: 10)
            ) == "SELECT \"id\" FROM \"orders\" WHERE total > 10 LIMIT 10")
    }

    /// The text is spliced into this statement, so the rule that a filter is one expression is what
    /// stops a second statement riding in with it.
    @Test
    func aFilterCarryingASecondStatementIsRefused() {
        #expect(ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: nil, driver: driver, databaseType: .postgresql,
                scope: PluginExportRowScope(filter: "1=1; DROP TABLE orders")
            ) == "SELECT \"id\" FROM \"orders\"")
    }

    @Test
    func aTrailingSemicolonIsATypingHabitRatherThanARefusal() {
        #expect(ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: nil, driver: driver, databaseType: .postgresql,
                scope: PluginExportRowScope(filter: "total > 10;")
            ) == "SELECT \"id\" FROM \"orders\" WHERE total > 10")
    }

    // MARK: - Estimates

    /// The driver counts the whole table, so a filtered step would show a bar running to a total it
    /// can never reach.
    @Test
    func aFilteredTableReportsNoEstimate() {
        #expect(ObjectCopyPlanner.estimate(
            5_000, scope: PluginExportRowScope(filter: "total > 10")
        ) == nil)
        #expect(ObjectCopyPlanner.estimate(5_000, scope: PluginExportRowScope(filter: "total > 10", rowLimit: 20)) == 20)
    }

    @Test
    func aRowLimitIsACeilingOnTheEstimate() {
        #expect(ObjectCopyPlanner.estimate(5_000, scope: PluginExportRowScope(rowLimit: 20)) == 20)
        #expect(ObjectCopyPlanner.estimate(10, scope: PluginExportRowScope(rowLimit: 20)) == 10)
        #expect(ObjectCopyPlanner.estimate(nil, scope: PluginExportRowScope(rowLimit: 20)) == 20)
        #expect(ObjectCopyPlanner.estimate(5_000, scope: nil) == 5_000)
    }
}
