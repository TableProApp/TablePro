//
//  SQLSchemaProviderFallbackTests.swift
//  TableProTests
//
//  Tests for allColumnsFromCachedTables() fallback completion
//  and eager column loading via populateColumnCache.
//

import Foundation
@testable import TablePro
import Testing

// MARK: - Mock Driver

private final class MockFallbackDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var tablesToReturn: [TableInfo] = []
    var columnsPerTable: [String: [ColumnInfo]] = [:]
    var fetchColumnsCallCount = 0
    var fetchAllColumnsCallCount = 0

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
        return columnsPerTable[table.lowercased()] ?? []
    }

    func fetchAllColumns() async throws -> [String: [ColumnInfo]] {
        fetchAllColumnsCallCount += 1
        return columnsPerTable
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

// MARK: - Helper

/// Populate the column cache by calling getColumns for each table in the driver.
/// This is deterministic (no timing dependency on eager load tasks).
private func populateCache(
    provider: SQLSchemaProvider,
    driver: MockFallbackDriver
) async {
    for tableName in driver.columnsPerTable.keys {
        _ = await provider.getColumns(for: tableName)
    }
}

// MARK: - Tests

@Suite("SQLSchemaProvider Fallback Columns", .serialized)
@MainActor
struct SQLSchemaProviderFallbackTests {
    // MARK: - allColumnsFromCachedTables

    @Test("Empty cache returns no fallback columns")
    func emptyCache() async {
        let provider = SQLSchemaProvider()
        let items = await provider.allColumnsFromCachedTables()
        #expect(items.isEmpty)
    }

    @Test("Single table columns have plain labels")
    func singleTablePlainLabels() async {
        let driver = MockFallbackDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        driver.columnsPerTable = [
            "users": [
                TestFixtures.makeColumnInfo(name: "id"),
                TestFixtures.makeColumnInfo(name: "name", dataType: "VARCHAR", isPrimaryKey: false)
            ]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())
        await populateCache(provider: provider, driver: driver)

        let items = await provider.allColumnsFromCachedTables()
        #expect(items.count == 2)

        let labels = items.map(\.label).sorted()
        #expect(labels == ["id", "name"])
        // No table prefix since there's only one table
        #expect(!labels.contains(where: { $0.contains(".") }))
    }

    @Test("Ambiguous columns get table-qualified labels")
    func ambiguousColumnsQualified() async {
        let driver = MockFallbackDriver()
        driver.tablesToReturn = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]
        driver.columnsPerTable = [
            "users": [TestFixtures.makeColumnInfo(name: "id")],
            "orders": [TestFixtures.makeColumnInfo(name: "id")]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())
        await populateCache(provider: provider, driver: driver)

        let items = await provider.allColumnsFromCachedTables()
        #expect(items.count == 2)

        let labels = Set(items.map(\.label))
        #expect(labels.contains("users.id"))
        #expect(labels.contains("orders.id"))
    }

    @Test("Unique columns stay plain with multiple tables")
    func uniqueColumnsPlain() async {
        let driver = MockFallbackDriver()
        driver.tablesToReturn = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]
        driver.columnsPerTable = [
            "users": [TestFixtures.makeColumnInfo(name: "name", dataType: "VARCHAR", isPrimaryKey: false)],
            "orders": [TestFixtures.makeColumnInfo(name: "total", dataType: "DECIMAL", isPrimaryKey: false)]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())
        await populateCache(provider: provider, driver: driver)

        let items = await provider.allColumnsFromCachedTables()
        #expect(items.count == 2)

        let labels = Set(items.map(\.label))
        #expect(labels.contains("name"))
        #expect(labels.contains("total"))
        #expect(!labels.contains(where: { $0.contains(".") }))
    }

    @Test("InsertText matches label for ambiguous columns")
    func insertTextMatchesLabelAmbiguous() async {
        let driver = MockFallbackDriver()
        driver.tablesToReturn = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]
        driver.columnsPerTable = [
            "users": [TestFixtures.makeColumnInfo(name: "id")],
            "orders": [TestFixtures.makeColumnInfo(name: "id")]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())
        await populateCache(provider: provider, driver: driver)

        let items = await provider.allColumnsFromCachedTables()
        for item in items {
            #expect(item.insertText == item.label)
        }
    }

    @Test("InsertText is plain column name for unique columns")
    func insertTextPlainForUnique() async {
        let driver = MockFallbackDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        driver.columnsPerTable = [
            "users": [TestFixtures.makeColumnInfo(name: "email", dataType: "VARCHAR", isPrimaryKey: false)]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())
        await populateCache(provider: provider, driver: driver)

        let items = await provider.allColumnsFromCachedTables()
        #expect(items.count == 1)
        #expect(items[0].insertText == "email")
        #expect(items[0].label == "email")
    }

    @Test("Fallback columns have sortPriority 150")
    func fallbackSortPriority() async {
        let driver = MockFallbackDriver()
        driver.tablesToReturn = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]
        driver.columnsPerTable = [
            "users": [TestFixtures.makeColumnInfo(name: "id"), TestFixtures.makeColumnInfo(name: "name", dataType: "VARCHAR", isPrimaryKey: false)],
            "orders": [TestFixtures.makeColumnInfo(name: "total", dataType: "DECIMAL", isPrimaryKey: false)]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())
        await populateCache(provider: provider, driver: driver)

        let items = await provider.allColumnsFromCachedTables()
        #expect(!items.isEmpty)
        for item in items {
            #expect(item.sortPriority == 150)
        }
    }

    @Test("Fallback items have column kind")
    func fallbackItemsAreColumns() async {
        let driver = MockFallbackDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        driver.columnsPerTable = [
            "users": [
                TestFixtures.makeColumnInfo(name: "id"),
                TestFixtures.makeColumnInfo(name: "name", dataType: "VARCHAR", isPrimaryKey: false)
            ]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())
        await populateCache(provider: provider, driver: driver)

        let items = await provider.allColumnsFromCachedTables()
        #expect(!items.isEmpty)
        for item in items {
            #expect(item.kind == .column)
        }
    }

    @Test("Mixed ambiguous and unique columns labelled correctly")
    func mixedAmbiguousAndUnique() async {
        let driver = MockFallbackDriver()
        driver.tablesToReturn = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]
        driver.columnsPerTable = [
            "users": [
                TestFixtures.makeColumnInfo(name: "id"),
                TestFixtures.makeColumnInfo(name: "name", dataType: "VARCHAR", isPrimaryKey: false)
            ],
            "orders": [
                TestFixtures.makeColumnInfo(name: "id"),
                TestFixtures.makeColumnInfo(name: "total", dataType: "DECIMAL", isPrimaryKey: false)
            ]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())
        await populateCache(provider: provider, driver: driver)

        let items = await provider.allColumnsFromCachedTables()
        #expect(items.count == 4)

        let labels = Set(items.map(\.label))
        // "id" is ambiguous -> table-qualified
        #expect(labels.contains("users.id"))
        #expect(labels.contains("orders.id"))
        // "name" and "total" are unique -> plain
        #expect(labels.contains("name"))
        #expect(labels.contains("total"))
    }

    @Test("Column name deduplication is case insensitive")
    func caseInsensitiveDedup() async {
        let driver = MockFallbackDriver()
        driver.tablesToReturn = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]
        driver.columnsPerTable = [
            "users": [TestFixtures.makeColumnInfo(name: "ID")],
            "orders": [TestFixtures.makeColumnInfo(name: "id")]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())
        await populateCache(provider: provider, driver: driver)

        let items = await provider.allColumnsFromCachedTables()
        #expect(items.count == 2)

        // Both should be table-qualified since "ID" and "id" collide case-insensitively
        let labels = Set(items.map(\.label))
        #expect(labels.contains("users.ID"))
        #expect(labels.contains("orders.id"))
    }

    @Test("Fallback items preserve column metadata in detail string")
    func fallbackItemsPreserveMetadata() async {
        let driver = MockFallbackDriver()
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        driver.columnsPerTable = [
            "users": [
                TestFixtures.makeColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true)
            ]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())
        await populateCache(provider: provider, driver: driver)

        let items = await provider.allColumnsFromCachedTables()
        #expect(items.count == 1)

        let item = items[0]
        // detail should contain PK, NOT NULL, and INT
        #expect(item.detail?.contains("PK") == true)
        #expect(item.detail?.contains("NOT NULL") == true)
        #expect(item.detail?.contains("INT") == true)
    }

    // MARK: - Eager Column Loading

    @Test("resetForDatabase triggers eager column load via fetchAllColumns")
    func resetForDatabaseTriggersEagerLoad() async throws {
        let driver = MockFallbackDriver()
        driver.tablesToReturn = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]
        driver.columnsPerTable = [
            "users": [TestFixtures.makeColumnInfo(name: "id")],
            "orders": [TestFixtures.makeColumnInfo(name: "order_id")]
        ]

        let provider = SQLSchemaProvider()
        await provider.resetForDatabase(
            "testdb",
            tables: driver.tablesToReturn,
            driver: driver
        )

        // Wait for the background eager load task to complete
        try await Task.sleep(nanoseconds: 300_000_000)

        // Eager load should have called fetchAllColumns
        #expect(driver.fetchAllColumnsCallCount >= 1)

        // The cache should now be populated -- getColumns should NOT trigger fetchColumns
        let fetchCountBefore = driver.fetchColumnsCallCount
        let columns = await provider.getColumns(for: "users")
        #expect(!columns.isEmpty)
        #expect(driver.fetchColumnsCallCount == fetchCountBefore)
    }

    @Test("Eager load does not overwrite manually cached columns")
    func eagerLoadDoesNotOverwriteCache() async throws {
        let driver = MockFallbackDriver()
        driver.tablesToReturn = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]
        driver.columnsPerTable = [
            "users": [
                TestFixtures.makeColumnInfo(name: "id"),
                TestFixtures.makeColumnInfo(name: "email", dataType: "VARCHAR", isPrimaryKey: false)
            ],
            "orders": [TestFixtures.makeColumnInfo(name: "order_id")]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())

        // Manually cache "users" columns via getColumns
        let manualColumns = await provider.getColumns(for: "users")
        #expect(manualColumns.count == 2)

        // Now trigger eager load -- it should NOT overwrite "users" cache entry
        await provider.resetForDatabase("testdb", tables: driver.tablesToReturn, driver: driver)
        try await Task.sleep(nanoseconds: 300_000_000)

        // "users" should still be the original cached version
        let cachedColumns = await provider.getColumns(for: "users")
        #expect(cachedColumns.count == 2)
    }

    @Test("Eager load respects maxCachedTables limit")
    func eagerLoadRespectsMaxCachedTables() async throws {
        let driver = MockFallbackDriver()
        var tables: [TableInfo] = []
        for i in 0..<60 {
            let name = "table_\(i)"
            tables.append(TestFixtures.makeTableInfo(name: name))
            driver.columnsPerTable[name] = [
                TestFixtures.makeColumnInfo(name: "col_\(i)", isPrimaryKey: false)
            ]
        }
        driver.tablesToReturn = tables

        let provider = SQLSchemaProvider()
        await provider.resetForDatabase("testdb", tables: tables, driver: driver)

        // Wait for the eager load task
        try await Task.sleep(nanoseconds: 300_000_000)

        // allColumnsFromCachedTables should return at most 50 tables worth of columns
        let items = await provider.allColumnsFromCachedTables()
        #expect(items.count <= 50)
    }

    @Test("allColumnsFromCachedTables uses canonical table names from tables list")
    func canonicalTableNames() async {
        let driver = MockFallbackDriver()
        // Table list has mixed-case name
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "Users")]
        // Column cache stores under lowercased key via getColumns
        driver.columnsPerTable = [
            "users": [TestFixtures.makeColumnInfo(name: "name", dataType: "VARCHAR", isPrimaryKey: false)]
        ]

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: driver, connection: TestFixtures.makeConnection())
        // getColumns lowercases the key, but the canonical name should be "Users"
        _ = await provider.getColumns(for: "Users")

        let items = await provider.allColumnsFromCachedTables()
        #expect(items.count == 1)
        // Since only one table, label should be plain
        #expect(items[0].label == "name")
        // Documentation should reference the canonical table name "Users"
        #expect(items[0].documentation?.contains("Users") == true)
    }
}
