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
}
