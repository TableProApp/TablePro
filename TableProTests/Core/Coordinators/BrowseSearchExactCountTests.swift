//
//  BrowseSearchExactCountTests.swift
//  TableProTests
//
//  A Redis tab narrowed by its key pattern bar or type picker runs that search instead of the
//  table filters. `Count Exactly` has to count the same search, or it reports the whole
//  database's key count as the exact total of a narrowed grid.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class BrowseCountStubDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [[PluginQueryFilter]] = []

    var receivedFilters: [[PluginQueryFilter]] {
        lock.withLock { received }
    }

    func fetchExactRowCount(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        lock.withLock { received.append(queryFilters) }
        return 3
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func connect() async throws {}
    func disconnect() {}
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

struct BrowseSearchExactCountTests {
    @Test("The count receives the key pattern and type the browse searched by")
    func countReceivesTheBrowseSearch() async throws {
        let stub = BrowseCountStubDriver()
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .redis), pluginDriver: stub)
        let search = BrowseSearchState(pattern: "  session:* ", typeScope: "hash")

        let count = try await adapter.fetchExactRowCount(table: "db0", browseFilters: search.pluginQueryFilters)

        #expect(count == 3)
        let received = try #require(stub.receivedFilters.first)
        #expect(received.map(\.column) == ["Key", "Type"])
        #expect(received.map(\.op) == ["MATCH", "="])
        #expect(received.map(\.value) == ["session:*", "hash"])
    }

    @Test("The Redis builder reads the search's filters as the scope the browse scans")
    func redisReadsTheSearchAsItsScope() {
        let filters = BrowseSearchState(pattern: "cart:*", typeScope: "list").pluginQueryFilters
        let scope = RedisQueryBuilder().browseScope(
            filters: filters.map { (column: $0.column, op: $0.op, value: $0.value) }
        )
        #expect(scope.pattern == "cart:*")
        #expect(scope.typeScope == "list")
    }

    @Test("An inactive search narrows nothing")
    func inactiveSearchHasNoFilters() {
        #expect(BrowseSearchState().pluginQueryFilters.isEmpty)
        #expect(BrowseSearchState(pattern: "   ").pluginQueryFilters.isEmpty)
    }
}
