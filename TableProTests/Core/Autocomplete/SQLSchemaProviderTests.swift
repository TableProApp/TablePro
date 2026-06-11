//
//  SQLSchemaProviderTests.swift
//  TableProTests
//
//  Tests for lazy schema column loading with LRU cache eviction.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// MARK: - Mock Driver

final class MockDatabaseDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var tablesToReturn: [TableInfo] = []
    var schemaTablesToReturn: [String: [TableInfo]] = [:]
    var columnsToReturn: [String: [ColumnInfo]] = [:]
    var fetchColumnsCallCount = 0
    var fetchColumnsCalls: [String] = []
    var fetchSchemaTablesCalls: [String] = []
    var applyQueryTimeoutValues: [Int] = []
    var cancelQueryCallCount = 0

    init(connection: DatabaseConnection = TestFixtures.makeConnection()) {
        self.connection = connection
    }

    func connect() async throws {}
    func disconnect() {}

    func testConnection() async throws -> Bool { true }

    func applyQueryTimeout(_ seconds: Int) async throws {
        applyQueryTimeoutValues.append(seconds)
    }

    func execute(query: String) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func fetchTables() async throws -> [TableInfo] {
        tablesToReturn
    }

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        guard let schema else { return tablesToReturn }
        fetchSchemaTablesCalls.append(schema)
        return schemaTablesToReturn[schema] ?? tablesToReturn
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
    func cancelQuery() throws { cancelQueryCallCount += 1 }
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

    @Test("getColumns uses injected metadata source instead of cached driver")
    func getColumnsUsesMetadataSource() async {
        let driver = MockDatabaseDriver()
        driver.columnsToReturn = ["users": [TestFixtures.makeColumnInfo(name: "from_driver")]]
        let source = SQLSchemaProvider.ColumnMetadataSource(
            fetchColumns: { _, _ in [TestFixtures.makeColumnInfo(name: "from_source")] },
            fetchAllColumns: { [:] }
        )
        let provider = SQLSchemaProvider(metadataSource: source)
        await provider.resetForDatabase("db", tables: [TestFixtures.makeTableInfo(name: "users")], driver: driver)

        let columns = await provider.getColumns(for: "users")
        #expect(columns.first?.name == "from_source")
        #expect(driver.fetchColumnsCallCount == 0)
    }

    @Test("eager column load uses injected metadata source instead of cached driver")
    func eagerLoadUsesMetadataSource() async throws {
        let driver = MockDatabaseDriver()
        driver.columnsToReturn = ["users": [TestFixtures.makeColumnInfo(name: "from_driver")]]
        let source = SQLSchemaProvider.ColumnMetadataSource(
            fetchColumns: { _, _ in [TestFixtures.makeColumnInfo(name: "lazy_source")] },
            fetchAllColumns: { ["users": [TestFixtures.makeColumnInfo(name: "eager_source")]] }
        )
        let provider = SQLSchemaProvider(metadataSource: source)
        await provider.resetForDatabase("db", tables: [TestFixtures.makeTableInfo(name: "users")], driver: driver)

        try await Task.sleep(nanoseconds: 300_000_000)

        let columns = await provider.getColumns(for: "users")
        #expect(columns.first?.name == "eager_source")
        #expect(driver.fetchColumnsCallCount == 0)
    }

    // MARK: - Namespaces (database/schema segments)

    @Test("isKnownSchema and isKnownDatabase match case-insensitively")
    func knownNamespaceLookupIsCaseInsensitive() async {
        let provider = SQLSchemaProvider()
        await provider.setNamespaces(schemas: ["DBT_MARTS"], databases: ["ANALYTICS_PROD"])

        #expect(await provider.isKnownSchema("dbt_marts"))
        #expect(await provider.isKnownSchema("DBT_MARTS"))
        #expect(!(await provider.isKnownSchema("unknown")))
        #expect(await provider.isKnownDatabase("analytics_prod"))
        #expect(!(await provider.isKnownDatabase("dbt_marts")))
    }

    @Test("namespaceCompletionItems lists databases and schemas")
    func namespaceCompletionItemsListsBoth() async {
        let provider = SQLSchemaProvider()
        await provider.setNamespaces(schemas: ["sales", "hr"], databases: ["prod"])

        let labels = await provider.namespaceCompletionItems().map(\.label)
        #expect(Set(labels) == ["prod", "sales", "hr"])
        #expect(await provider.namespaceCompletionItems().allSatisfy { $0.kind == .schema })
    }

    @Test("schemaCompletionItems lists schemas only")
    func schemaCompletionItemsListsSchemasOnly() async {
        let provider = SQLSchemaProvider()
        await provider.setNamespaces(schemas: ["sales", "hr"], databases: ["prod"])

        let labels = await provider.schemaCompletionItems().map(\.label)
        #expect(Set(labels) == ["sales", "hr"])
    }

    @Test("tableCompletionItems filters already-loaded tables by schema")
    func tableCompletionItemsFiltersLoadedBySchema() async {
        let driver = MockDatabaseDriver()
        let provider = SQLSchemaProvider()
        await provider.resetForDatabase(
            "db",
            tables: [
                TableInfo(name: "orders", type: .table, rowCount: 0, schema: "sales"),
                TableInfo(name: "leads", type: .table, rowCount: 0, schema: "sales"),
                TableInfo(name: "employees", type: .table, rowCount: 0, schema: "hr")
            ],
            driver: driver
        )

        let labels = await provider.tableCompletionItems(inSchema: "sales").map(\.label)
        #expect(Set(labels) == ["orders", "leads"])
    }

    @Test("tableCompletionItems fetches a schema's tables on demand when not loaded")
    func tableCompletionItemsFetchesOnDemand() async {
        let source = SQLSchemaProvider.ColumnMetadataSource(
            fetchColumns: { _, _ in [] },
            fetchAllColumns: { [:] },
            fetchSchemaTables: { schema in
                [TableInfo(name: "fact_orders", type: .table, rowCount: 0, schema: schema)]
            }
        )
        let provider = SQLSchemaProvider(metadataSource: source)

        let labels = await provider.tableCompletionItems(inSchema: "marts").map(\.label)
        #expect(labels == ["fact_orders"])
    }

    @Test("tableCompletionItems drops fetched tables that belong to a different schema")
    func tableCompletionItemsDefensivelyFiltersFetched() async {
        let source = SQLSchemaProvider.ColumnMetadataSource(
            fetchColumns: { _, _ in [] },
            fetchAllColumns: { [:] },
            fetchSchemaTables: { _ in
                [
                    TableInfo(name: "in_schema", type: .table, rowCount: 0, schema: "marts"),
                    TableInfo(name: "other_schema", type: .table, rowCount: 0, schema: "staging"),
                    TableInfo(name: "untagged", type: .table, rowCount: 0, schema: nil)
                ]
            }
        )
        let provider = SQLSchemaProvider(metadataSource: source)

        let labels = await provider.tableCompletionItems(inSchema: "marts").map(\.label)
        #expect(Set(labels) == ["in_schema", "untagged"])
    }

    @Test("getColumns threads the schema through to the metadata source and caches per schema")
    func getColumnsThreadsSchemaAndCachesPerSchema() async {
        let recorder = CallRecorder()
        let source = SQLSchemaProvider.ColumnMetadataSource(
            fetchColumns: { table, schema in
                recorder.record("\(schema ?? "nil").\(table)")
                return [TestFixtures.makeColumnInfo(name: "\(schema ?? "nil")_col")]
            },
            fetchAllColumns: { [:] }
        )
        let provider = SQLSchemaProvider(metadataSource: source)

        let sales = await provider.getColumns(for: "orders", schema: "sales")
        let hr = await provider.getColumns(for: "orders", schema: "hr")
        _ = await provider.getColumns(for: "orders", schema: "sales")

        #expect(sales.first?.name == "sales_col")
        #expect(hr.first?.name == "hr_col")
        #expect(recorder.calls == ["sales.orders", "hr.orders"])
    }
}

private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
