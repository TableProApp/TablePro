//
//  ObjectCopySelectQueryTests.swift
//  TableProTests
//
//  The read side of a copy names its columns, in the order the INSERT will
//  write them, so the stream and the statement cannot drift apart.
//

@testable import TablePro
import TableProPluginKit
import XCTest

private final class QuotingDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let injectsRowLimit: Bool

    init(injectsRowLimit: Bool = true) {
        self.injectsRowLimit = injectsRowLimit
    }

    func connect() async throws {}
    func disconnect() {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }
    func injectRowLimit(_ query: String, limit: Int) -> String? {
        injectsRowLimit ? "\(query) LIMIT \(limit)" : nil
    }
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

final class ObjectCopySelectQueryTests: XCTestCase {
    private let driver = QuotingDriver()

    func testColumnsAreNamedAndQuotedInOrder() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id", "total"], table: "orders", schema: "public", driver: driver,
                databaseType: .postgresql
            ),
            "SELECT \"id\", \"total\" FROM \"public\".\"orders\""
        )
    }

    func testAnUnqualifiedTableKeepsThePlainName() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: nil, driver: driver, databaseType: .postgresql
            ),
            "SELECT \"id\" FROM \"orders\""
        )
    }

    func testAnEmptySchemaIsTreatedAsNoSchema() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: "", driver: driver, databaseType: .postgresql
            ),
            "SELECT \"id\" FROM \"orders\""
        )
    }

    func testTheEngineImplicitSchemaIsLeftUnqualified() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: "(default)", driver: driver, databaseType: .spanner
            ),
            "SELECT \"id\" FROM \"orders\""
        )
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: "sales", driver: driver, databaseType: .spanner
            ),
            "SELECT \"id\" FROM \"sales\".\"orders\""
        )
    }

    /// A structure-only step has no columns, and a star select is the honest fallback rather than
    /// a `SELECT  FROM`.
    func testNoColumnsFallsBackToStar() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: [], table: "orders", schema: nil, driver: driver, databaseType: .postgresql
            ),
            "SELECT * FROM \"orders\""
        )
    }

    // MARK: - Row scope

    func testAFilterBecomesAWhereClause() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: nil, driver: driver, databaseType: .postgresql,
                scope: PluginExportRowScope(filter: "total > 10")
            ),
            "SELECT \"id\" FROM \"orders\" WHERE total > 10"
        )
    }

    /// Through the driver's own injection, because `LIMIT` is not the spelling on SQL Server or on
    /// Oracle before 12c.
    func testARowLimitGoesThroughTheDriver() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: nil, driver: driver, databaseType: .postgresql,
                scope: PluginExportRowScope(filter: "total > 10", rowLimit: 50)
            ),
            "SELECT \"id\" FROM \"orders\" WHERE total > 10 LIMIT 50"
        )
    }

    func testARowLimitTheDriverCannotInjectIsSpelledForSQLServer() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: "dbo", driver: QuotingDriver(injectsRowLimit: false),
                databaseType: .mssql, scope: PluginExportRowScope(filter: "total > 10", rowLimit: 10)
            ),
            "SELECT TOP 10 \"id\" FROM \"dbo\".\"orders\" WHERE total > 10"
        )
    }

    func testARowLimitTheDriverCannotInjectIsSpelledForOracle() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["ID"], table: "ORDERS", schema: "HR", driver: QuotingDriver(injectsRowLimit: false),
                databaseType: .oracle, scope: PluginExportRowScope(filter: "TOTAL > 10", rowLimit: 10)
            ),
            "SELECT \"ID\" FROM \"HR\".\"ORDERS\" WHERE TOTAL > 10 FETCH FIRST 10 ROWS ONLY"
        )
    }

    func testARowLimitTheDriverCannotInjectIsSpelledForDamengWithoutSorting() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["DOC"], table: "ORDERS", schema: "SYSDBA", driver: QuotingDriver(injectsRowLimit: false),
                databaseType: .dameng, scope: PluginExportRowScope(rowLimit: 10)
            ),
            "SELECT \"DOC\" FROM \"SYSDBA\".\"ORDERS\" FETCH FIRST 10 ROWS ONLY"
        )
    }

    func testARowLimitTheDriverCannotInjectStaysLimitOnTrino() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: "sales", driver: QuotingDriver(injectsRowLimit: false),
                databaseType: .trino, scope: PluginExportRowScope(rowLimit: 10)
            ),
            "SELECT \"id\" FROM \"sales\".\"orders\" LIMIT 10"
        )
    }

    func testARowLimitTheDriverCannotInjectIsSpelledForTeradata() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: "sales", driver: QuotingDriver(injectsRowLimit: false),
                databaseType: .teradata, scope: PluginExportRowScope(rowLimit: 10)
            ),
            "SELECT TOP 10 \"id\" FROM \"sales\".\"orders\""
        )
    }

    func testARowLimitTheDriverCannotInjectStaysLimitOnMySQL() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: nil, driver: QuotingDriver(injectsRowLimit: false),
                databaseType: .mysql, scope: PluginExportRowScope(filter: "total > 10", rowLimit: 10)
            ),
            "SELECT \"id\" FROM \"orders\" WHERE total > 10 LIMIT 10"
        )
    }

    /// The text is spliced into this statement, so the rule that a filter is one expression is what
    /// stops a second statement riding in with it.
    func testAFilterCarryingASecondStatementIsRefused() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: nil, driver: driver, databaseType: .postgresql,
                scope: PluginExportRowScope(filter: "1=1; DROP TABLE orders")
            ),
            "SELECT \"id\" FROM \"orders\""
        )
    }

    func testATrailingSemicolonIsATypingHabitRatherThanARefusal() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: nil, driver: driver, databaseType: .postgresql,
                scope: PluginExportRowScope(filter: "total > 10;")
            ),
            "SELECT \"id\" FROM \"orders\" WHERE total > 10"
        )
    }

    // MARK: - Estimates

    /// The driver counts the whole table, so a filtered step would show a bar running to a total it
    /// can never reach.
    func testAFilteredTableReportsNoEstimate() {
        XCTAssertNil(ObjectCopyPlanner.estimate(
            5_000, scope: PluginExportRowScope(filter: "total > 10")
        ))
        XCTAssertEqual(
            ObjectCopyPlanner.estimate(5_000, scope: PluginExportRowScope(filter: "total > 10", rowLimit: 20)),
            20
        )
    }

    func testARowLimitIsACeilingOnTheEstimate() {
        XCTAssertEqual(ObjectCopyPlanner.estimate(5_000, scope: PluginExportRowScope(rowLimit: 20)), 20)
        XCTAssertEqual(ObjectCopyPlanner.estimate(10, scope: PluginExportRowScope(rowLimit: 20)), 10)
        XCTAssertEqual(ObjectCopyPlanner.estimate(nil, scope: PluginExportRowScope(rowLimit: 20)), 20)
        XCTAssertEqual(ObjectCopyPlanner.estimate(5_000, scope: nil), 5_000)
    }
}
