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
    func connect() async throws {}
    func disconnect() {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }
    func injectRowLimit(_ query: String, limit: Int) -> String? { "\(query) LIMIT \(limit)" }
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
                columns: ["id", "total"], table: "orders", schema: "public", driver: driver
            ),
            "SELECT \"id\", \"total\" FROM \"public\".\"orders\""
        )
    }

    func testAnUnqualifiedTableKeepsThePlainName() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(columns: ["id"], table: "orders", schema: nil, driver: driver),
            "SELECT \"id\" FROM \"orders\""
        )
    }

    func testAnEmptySchemaIsTreatedAsNoSchema() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(columns: ["id"], table: "orders", schema: "", driver: driver),
            "SELECT \"id\" FROM \"orders\""
        )
    }

    /// A structure-only step has no columns, and a star select is the honest fallback rather than
    /// a `SELECT  FROM`.
    func testNoColumnsFallsBackToStar() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(columns: [], table: "orders", schema: nil, driver: driver),
            "SELECT * FROM \"orders\""
        )
    }

    // MARK: - Row scope

    func testAFilterBecomesAWhereClause() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: nil, driver: driver,
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
                columns: ["id"], table: "orders", schema: nil, driver: driver,
                scope: PluginExportRowScope(filter: "total > 10", rowLimit: 50)
            ),
            "SELECT \"id\" FROM \"orders\" WHERE total > 10 LIMIT 50"
        )
    }

    /// The text is spliced into this statement, so the rule that a filter is one expression is what
    /// stops a second statement riding in with it.
    func testAFilterCarryingASecondStatementIsRefused() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: nil, driver: driver,
                scope: PluginExportRowScope(filter: "1=1; DROP TABLE orders")
            ),
            "SELECT \"id\" FROM \"orders\""
        )
    }

    func testATrailingSemicolonIsATypingHabitRatherThanARefusal() {
        XCTAssertEqual(
            ObjectCopySelectQuery.build(
                columns: ["id"], table: "orders", schema: nil, driver: driver,
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
