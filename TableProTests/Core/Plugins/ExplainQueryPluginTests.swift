//
//  ExplainQueryPluginTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

/// Minimal stub implementing PluginDatabaseDriver for testing buildExplainQuery.
/// Returns a fixed explain string or nil depending on configuration.
private final class StubExplainDriver: PluginDatabaseDriver {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    private let explainResult: ((String) -> String?)?

    init(explainResult: ((String) -> String?)? = nil) {
        self.explainResult = explainResult
    }

    func buildExplainQuery(_ sql: String) -> String? {
        explainResult?(sql)
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchRowCount(query: String) async throws -> Int { 0 }
    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
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

@Suite("buildExplainQuery plugin protocol")
struct ExplainQueryPluginTests {
    @Test("Default implementation returns nil")
    func defaultReturnsNil() {
        let driver = StubExplainDriver()
        #expect(driver.buildExplainQuery("SELECT 1") == nil)
    }

    @Test("Custom implementation returns explain SQL")
    func customReturnsExplain() {
        let driver = StubExplainDriver { sql in
            "EXPLAIN \(sql)"
        }
        #expect(driver.buildExplainQuery("SELECT * FROM users") == "EXPLAIN SELECT * FROM users")
    }

    @Test("SQLite-style EXPLAIN QUERY PLAN")
    func sqliteStyleExplain() {
        let driver = StubExplainDriver { sql in
            "EXPLAIN QUERY PLAN \(sql)"
        }
        let result = driver.buildExplainQuery("SELECT id FROM items")
        #expect(result == "EXPLAIN QUERY PLAN SELECT id FROM items")
    }

    @Test("Unsupported database returns nil")
    func unsupportedReturnsNil() {
        let driver = StubExplainDriver { _ in nil }
        #expect(driver.buildExplainQuery("SELECT 1") == nil)
    }
}
