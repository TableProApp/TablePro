//
//  LiveTableFetcherTests.swift
//  TableProTests
//
//  Tests for LiveTableFetcher schema provider cache integration.
//

import Foundation
import Testing
@testable import TablePro

// MARK: - Mock DatabaseDriver

private class MockDatabaseDriver: DatabaseDriver {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? = nil

    var tablesToReturn: [TableInfo] = []
    var fetchTablesCallCount = 0

    init(connection: DatabaseConnection = TestFixtures.makeConnection()) {
        self.connection = connection
    }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func applyQueryTimeout(_ seconds: Int) async throws {}

    func execute(query: String) async throws -> QueryResult { .empty }
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult { .empty }
    func fetchRowCount(query: String) async throws -> Int { 0 }
    func fetchRows(query: String, offset: Int, limit: Int) async throws -> QueryResult { .empty }

    func fetchTables() async throws -> [TableInfo] {
        fetchTablesCallCount += 1
        return tablesToReturn
    }

    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchAllColumns() async throws -> [String: [ColumnInfo]] { [:] }
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
    func fetchSchemas() async throws -> [String] { [] }
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

@Suite("LiveTableFetcher")
struct LiveTableFetcherTests {

    @Test("returns cached tables from schema provider when available")
    func returnsCachedTablesFromSchemaProvider() async throws {
        let expectedTables = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders"),
            TestFixtures.makeTableInfo(name: "products")
        ]

        let mockDriver = MockDatabaseDriver()
        mockDriver.tablesToReturn = expectedTables

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: mockDriver)

        let initialCallCount = mockDriver.fetchTablesCallCount
        #expect(initialCallCount == 1)

        let fetcher = LiveTableFetcher(connectionId: UUID(), schemaProvider: provider)
        let result = try await fetcher.fetchTables(force: false)

        #expect(result.count == 3)
        #expect(result.map(\.name) == ["users", "orders", "products"])
        #expect(mockDriver.fetchTablesCallCount == initialCallCount)
    }

    @Test("falls back to driver when schema provider has no cached tables")
    func fallsBackWhenSchemaProviderEmpty() async throws {
        let provider = SQLSchemaProvider()

        let fetcher = LiveTableFetcher(connectionId: UUID(), schemaProvider: provider)
        let result = try await fetcher.fetchTables(force: false)

        #expect(result.isEmpty)
    }

    @Test("works without schema provider using direct driver fetch")
    func worksWithoutSchemaProvider() async throws {
        let fetcher = LiveTableFetcher(connectionId: UUID())
        let result = try await fetcher.fetchTables(force: false)

        #expect(result.isEmpty)
    }

    @Test("schema provider with loaded tables returns them directly")
    func schemaProviderReturnsLoadedTablesConsistently() async throws {
        let expectedTables = [
            TestFixtures.makeTableInfo(name: "accounts"),
            TestFixtures.makeTableInfo(name: "transactions")
        ]

        let mockDriver = MockDatabaseDriver()
        mockDriver.tablesToReturn = expectedTables

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: mockDriver)

        let fetcher = LiveTableFetcher(connectionId: UUID(), schemaProvider: provider)

        for _ in 0..<3 {
            let result = try await fetcher.fetchTables(force: false)
            #expect(result.count == 2)
            #expect(result.map(\.name) == ["accounts", "transactions"])
        }

        #expect(mockDriver.fetchTablesCallCount == 1)
    }

    @Test("force: true bypasses schema provider cache and hits driver")
    func forceBypassesCache() async throws {
        let initialTables = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders")
        ]

        let mockDriver = MockDatabaseDriver()
        mockDriver.tablesToReturn = initialTables

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: mockDriver)

        let freshTables = [
            TestFixtures.makeTableInfo(name: "users"),
            TestFixtures.makeTableInfo(name: "orders"),
            TestFixtures.makeTableInfo(name: "new_table")
        ]
        mockDriver.tablesToReturn = freshTables

        let callCountBefore = mockDriver.fetchTablesCallCount

        let fetcher = LiveTableFetcher(connectionId: UUID(), schemaProvider: provider)
        let result = try await fetcher.fetchTables(force: true)

        #expect(result.count == 3)
        #expect(result.map(\.name) == ["users", "orders", "new_table"])
        #expect(mockDriver.fetchTablesCallCount == callCountBefore + 1)
    }

    @Test("force: true writes fresh tables back into schema provider")
    func forcedFetchUpdatesSchemaProvider() async throws {
        let initialTables = [TestFixtures.makeTableInfo(name: "old_table")]

        let mockDriver = MockDatabaseDriver()
        mockDriver.tablesToReturn = initialTables

        let provider = SQLSchemaProvider()
        await provider.loadSchema(using: mockDriver)

        let freshTables = [
            TestFixtures.makeTableInfo(name: "alpha"),
            TestFixtures.makeTableInfo(name: "beta")
        ]
        mockDriver.tablesToReturn = freshTables

        let fetcher = LiveTableFetcher(connectionId: UUID(), schemaProvider: provider)
        _ = try await fetcher.fetchTables(force: true)

        let cached = await provider.getTables()
        #expect(cached.map(\.name).sorted() == ["alpha", "beta"])
    }
}
