//
//  CompletionEngineFilterTests.swift
//  TableProTests
//
//  Tests for CompletionEngine.filterCompletions: completion of a raw SQL
//  filter fragment (a bare WHERE-clause expression) at every clause position.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class MockFilterDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var tablesToReturn: [TableInfo] = []
    var columnsPerTable: [String: [ColumnInfo]] = [:]

    init(connection: DatabaseConnection = TestFixtures.makeConnection()) {
        self.connection = connection
    }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func applyQueryTimeout(_ seconds: Int) async throws {}

    func execute(query: String) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func fetchTables() async throws -> [TableInfo] { tablesToReturn }

    func fetchColumns(table: String) async throws -> [ColumnInfo] {
        columnsPerTable[table.lowercased()] ?? []
    }

    func fetchAllColumns() async throws -> [String: [ColumnInfo]] { columnsPerTable }

    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }

    func fetchTableDDL(table: String) async throws -> String { "" }
    func fetchViewDefinition(view: String) async throws -> String { "" }

    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName, dataSize: nil, indexSize: nil, totalSize: nil,
            avgRowLength: nil, rowCount: nil, comment: nil, engine: nil,
            collation: nil, createTime: nil, updateTime: nil
        )
    }

    func fetchDatabases() async throws -> [String] { [] }

    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database, name: database, tableCount: nil, sizeBytes: nil,
            lastAccessed: nil, isSystemDatabase: false, icon: "cylinder"
        )
    }

    func createDatabase(name: String, charset: String, collation: String?) async throws {}
    func cancelQuery() throws {}
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}

@Suite("Completion Engine Filter Completions", .serialized)
@MainActor
struct CompletionEngineFilterTests {
    private func makeEngine() async -> CompletionEngine {
        let driver = MockFilterDriver()
        driver.tablesToReturn = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]
        driver.columnsPerTable = [
            "users": [
                TestFixtures.makeColumnInfo(name: "id"),
                TestFixtures.makeColumnInfo(name: "email"),
                TestFixtures.makeColumnInfo(name: "created_at"),
                TestFixtures.makeColumnInfo(name: "title")
            ],
            "orders": [TestFixtures.makeColumnInfo(name: "total")]
        ]

        let provider = SQLSchemaProvider()
        await provider.resetForDatabase("testdb", tables: driver.tablesToReturn, driver: driver)
        _ = await provider.getColumns(for: "users")
        _ = await provider.getColumns(for: "orders")

        return CompletionEngine(schemaProvider: provider, databaseType: .mysql)
    }

    @Test("Suggests columns after AND")
    func columnsAfterAnd() async {
        let engine = await makeEngine()
        let fragment = "id = 1 AND cre"
        let result = await engine.filterCompletions(
            fragment: fragment,
            cursorPosition: (fragment as NSString).length,
            tableName: "users"
        )
        let labels = result?.items.map(\.label) ?? []
        #expect(labels.contains("created_at"))
    }

    @Test("Replacement range covers the current token, not the whole field")
    func replacementRangeCoversToken() async {
        let engine = await makeEngine()
        let fragment = "id = 1 AND cre"
        let result = await engine.filterCompletions(
            fragment: fragment,
            cursorPosition: (fragment as NSString).length,
            tableName: "users"
        )
        #expect(result?.replacementRange == NSRange(location: 11, length: 3))
    }

    @Test("Suggests columns at the first token")
    func columnsAtFirstToken() async {
        let engine = await makeEngine()
        let fragment = "cre"
        let result = await engine.filterCompletions(
            fragment: fragment,
            cursorPosition: 3,
            tableName: "users"
        )
        let labels = result?.items.map(\.label) ?? []
        #expect(labels.contains("created_at"))
        #expect(result?.replacementRange == NSRange(location: 0, length: 3))
    }

    @Test("Scopes columns to the given table only")
    func scopesToTableOnly() async {
        let engine = await makeEngine()
        let fragment = "id = 1 AND t"
        let result = await engine.filterCompletions(
            fragment: fragment,
            cursorPosition: (fragment as NSString).length,
            tableName: "users"
        )
        let labels = result?.items.map(\.label) ?? []
        #expect(labels.contains("title"))
        #expect(!labels.contains("total"))
    }

    @Test("Suggests logical keywords after a complete condition")
    func keywordsAfterAnd() async {
        let engine = await makeEngine()
        let fragment = "id = 1 AND li"
        let result = await engine.filterCompletions(
            fragment: fragment,
            cursorPosition: (fragment as NSString).length,
            tableName: "users"
        )
        let labels = result?.items.map(\.label) ?? []
        #expect(labels.contains("LIKE"))
    }

    @Test("No completion inside a string literal")
    func noCompletionInsideString() async {
        let engine = await makeEngine()
        let fragment = "email = 'jo"
        let result = await engine.filterCompletions(
            fragment: fragment,
            cursorPosition: (fragment as NSString).length,
            tableName: "users"
        )
        #expect(result == nil)
    }
}
