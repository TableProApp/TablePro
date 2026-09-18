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

    /// The shared trigger rule exempts a qualified name whatever clause it sits in, and the filter
    /// path has to reach that exemption too: a dot is the user asking for a closed list.
    @Test("A qualified name on the filter path is exempt from the empty-prefix rule")
    func qualifiedNameIsExemptFromTheEmptyPrefixRule() async {
        let engine = await makeEngine()
        let fragment = "users."
        let result = await engine.filterCompletions(
            fragment: fragment,
            cursorPosition: (fragment as NSString).length,
            tableName: "users"
        )

        #expect(result?.sqlContext.dotPrefix == "users")
        #expect(
            result.map {
                SQLCompletionTriggerPolicy.suppressesEmptyPrefix($0.sqlContext, isManualTrigger: false)
            } == false
        )
    }

    /// An opening backtick is typed input, not an untouched position. The analyzer keeps it inside
    /// `prefixRange` so an accepted completion overwrites it and strips it from `prefix` so the
    /// matcher can work, so a trigger rule reading `prefix` alone shuts the list the quote opened.
    @Test("An opening backtick still opens the list", arguments: ["`", "id = 1 AND `"])
    func openingBacktickIsTypedInput(fragment: String) async {
        let engine = await makeEngine()
        let result = await engine.filterCompletions(
            fragment: fragment,
            cursorPosition: (fragment as NSString).length,
            tableName: "users"
        )

        #expect(result?.sqlContext.prefix.isEmpty == true)
        #expect(result?.sqlContext.prefixRange.isEmpty == false)
        #expect(
            result.map {
                SQLCompletionTriggerPolicy.suppressesEmptyPrefix($0.sqlContext, isManualTrigger: false)
            } == false
        )
        #expect(result?.items.contains { $0.label == "created_at" } == true)
    }

    /// A lone double quote opens a string literal on MySQL, and the analyzer reads it that way, so
    /// nothing is offered there whatever the trigger rule says.
    @Test("A lone double quote offers nothing, because it opens a string", arguments: ["\"", "id = 1 AND \""])
    func loneDoubleQuoteOffersNothing(fragment: String) async {
        let engine = await makeEngine()
        let result = await engine.filterCompletions(
            fragment: fragment,
            cursorPosition: (fragment as NSString).length,
            tableName: "users"
        )

        #expect(result == nil)
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
        #expect(labels.contains { $0.caseInsensitiveCompare("LIKE") == .orderedSame })
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
