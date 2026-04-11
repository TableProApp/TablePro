//
//  SQLSchemaProviderTests.swift
//  TableProTests
//
//  Tests for lazy schema column loading with LRU cache eviction.
//

import Foundation
import Testing
@testable import TablePro

// MARK: - Mock Driver

private final class MockDatabaseDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var tablesToReturn: [TableInfo] = []
    var columnsToReturn: [String: [ColumnInfo]] = [:]
    var fetchColumnsCallCount = 0
    var fetchColumnsCalls: [String] = []

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

    func fetchRowCount(query: String) async throws -> Int { 0 }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func fetchTables() async throws -> [TableInfo] {
        tablesToReturn
    }

    func fetchColumns(table: String) async throws -> [ColumnInfo] {
        fetchColumnsCallCount += 1
        fetchColumnsCalls.append(table)
        return columnsToReturn[table.lowercased()] ?? []
    }

    func fetchAllColumns() async throws -> [String: [ColumnInfo]] {
        [:]
    }

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

// MARK: - Tests

@Suite("SQLSchemaProvider")
@MainActor
struct SQLSchemaProviderTests {
    @Test("loadSchema fetches tables without bulk column loading")
    func loadSchemaOnlyFetchesTables() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]
        driver.columnsToReturn = [
            "users": [TestFixtures.makeColumnInfo(name: "id")],
            "orders": [TestFixtures.makeColumnInfo(name: "id")]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())

        let tables = await provider.getTables()
        #expect(tables.count == 2)
        #expect(driver.fetchColumnsCallCount == 0)
    }

    @Test("getColumns fetches from driver on cache miss")
    func getColumnsLazyFetchOnMiss() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        driver.columnsToReturn = [
            "users": [
                TestFixtures.makeColumnInfo(name: "id"),
                TestFixtures.makeColumnInfo(name: "email", dataType: "VARCHAR", isPrimaryKey: false)
            ]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())

        let columns = await provider.getColumns(for: "users")
        #expect(columns.count == 2)
        #expect(columns[0].name == "id")
        #expect(columns[1].name == "email")
        #expect(driver.fetchColumnsCallCount == 1)
        #expect(driver.fetchColumnsCalls == ["users"])
    }

    @Test("getColumns returns cached columns without driver call")
    func getColumnsCacheHit() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        driver.columnsToReturn = [
            "users": [TestFixtures.makeColumnInfo(name: "id")]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())

        _ = await provider.getColumns(for: "users")
        let columns = await provider.getColumns(for: "users")

        #expect(columns.count == 1)
        #expect(driver.fetchColumnsCallCount == 1)
    }

    @Test("evicts oldest columns when cache exceeds limit")
    func lruEvictionOnExceedingMax() async {
        let driver = MockDatabaseDriver()
        var allTables: [TableInfo] = []
        for i in 0..<52 {
            let name = "table_\(i)"
            allTables.append(TestFixtures.makeTableInfo(name: name))
            driver.columnsToReturn[name] = [
                TestFixtures.makeColumnInfo(name: "col_\(i)", isPrimaryKey: false)
            ]
        }
        driver.tablesToReturn = allTables

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())

        for i in 0..<52 {
            _ = await provider.getColumns(for: "table_\(i)")
        }

        #expect(driver.fetchColumnsCallCount == 52)

        // table_0 and table_1 should have been evicted (oldest entries)
        // Fetching them again should trigger new driver calls
        _ = await provider.getColumns(for: "table_0")
        _ = await provider.getColumns(for: "table_1")
        #expect(driver.fetchColumnsCallCount == 54)

        // table_51 should still be cached (no additional call)
        let countBefore = driver.fetchColumnsCallCount
        _ = await provider.getColumns(for: "table_51")
        #expect(driver.fetchColumnsCallCount == countBefore)
    }

    @Test("cache hit moves table to end of LRU order")
    func lruAccessOrderUpdate() async {
        let driver = MockDatabaseDriver()
        let tableNames = ["a", "b", "c"]
        for name in tableNames {
            driver.columnsToReturn[name] = [
                TestFixtures.makeColumnInfo(name: "\(name)_col", isPrimaryKey: false)
            ]
        }
        for i in 0..<49 {
            let name = "fill_\(i)"
            driver.columnsToReturn[name] = [
                TestFixtures.makeColumnInfo(name: "col", isPrimaryKey: false)
            ]
        }

        var allTables = tableNames.map { TestFixtures.makeTableInfo(name: $0) }
        allTables += (0..<49).map { TestFixtures.makeTableInfo(name: "fill_\($0)") }
        driver.tablesToReturn = allTables

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())

        // Fetch columns for A, B, C (in that order)
        _ = await provider.getColumns(for: "a")
        _ = await provider.getColumns(for: "b")
        _ = await provider.getColumns(for: "c")

        // Access A again (cache hit, moves A to end of LRU order)
        // LRU order is now: [b, c, a]
        _ = await provider.getColumns(for: "a")
        #expect(driver.fetchColumnsCallCount == 3)

        // Fill cache with 49 more tables (total becomes 52, evicting 2 oldest: b then c)
        for i in 0..<49 {
            _ = await provider.getColumns(for: "fill_\(i)")
        }

        // A should still be cached because it was moved to end of LRU order
        let countBeforeA = driver.fetchColumnsCallCount
        _ = await provider.getColumns(for: "a")
        #expect(driver.fetchColumnsCallCount == countBeforeA)

        // B and C should have been evicted (they were the oldest unused)
        let countBeforeBC = driver.fetchColumnsCallCount
        _ = await provider.getColumns(for: "b")
        _ = await provider.getColumns(for: "c")
        #expect(driver.fetchColumnsCallCount == countBeforeBC + 2)
    }

    @Test("resetForDatabase clears columns, updates tables, and sets driver")
    func resetForDatabaseClearsAndUpdates() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        driver.columnsToReturn = [
            "users": [TestFixtures.makeColumnInfo(name: "id")]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())
        _ = await provider.getColumns(for: "users")

        let newTables = [TestFixtures.makeTableInfo(name: "orders")]
        let newDriver = MockDatabaseDriver()
        await provider.resetForDatabase("new_db", tables: newTables, driver: newDriver)

        let tables = await provider.getTables()
        #expect(tables.count == 1)
        #expect(tables.first?.name == "orders")

        // Column cache should be cleared (requires re-fetch)
        newDriver.columnsToReturn = ["orders": [TestFixtures.makeColumnInfo(name: "order_id")]]
        let columns = await provider.getColumns(for: "orders")
        #expect(columns.first?.name == "order_id")
    }

    @Test("getColumns returns empty when driver is not available")
    func getColumnsWithoutDriver() async {
        let provider = SQLSchemaProvider()
        let columns = await provider.getColumns(for: "nonexistent")
        #expect(columns.isEmpty)
    }

    @Test("column cache is case-insensitive")
    func caseInsensitiveCache() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "Users")]
        driver.columnsToReturn = [
            "users": [TestFixtures.makeColumnInfo(name: "id")]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())

        _ = await provider.getColumns(for: "Users")
        _ = await provider.getColumns(for: "users")

        #expect(driver.fetchColumnsCallCount == 1)
    }

    @Test("allColumnsInScope with single reference returns unprefixed names")
    func allColumnsInScopeSingleRef() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        driver.columnsToReturn = [
            "users": [
                TestFixtures.makeColumnInfo(name: "id"),
                TestFixtures.makeColumnInfo(name: "email", dataType: "VARCHAR", isPrimaryKey: false)
            ]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())

        let ref = TableReference(tableName: "users", alias: nil)
        let items = await provider.allColumnsInScope(for: [ref])
        #expect(items.count == 2)
        #expect(items[0].label == "id")
        #expect(items[1].label == "email")
    }

    @Test("allColumnsInScope with multiple references returns prefixed names")
    func allColumnsInScopeMultipleRefs() async {
        let driver = MockDatabaseDriver()
        driver.tablesToReturn = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]
        driver.columnsToReturn = [
            "users": [TestFixtures.makeColumnInfo(name: "id")],
            "orders": [TestFixtures.makeColumnInfo(name: "id")]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())

        let refs = [
            TableReference(tableName: "users", alias: nil),
            TableReference(tableName: "orders", alias: nil)
        ]
        let items = await provider.allColumnsInScope(for: refs)
        #expect(items.count == 2)
        #expect(items[0].label == "users.id")
        #expect(items[1].label == "orders.id")
    }
}
