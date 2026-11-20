import Foundation
import os
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

// Two relations whose names differ only in Unicode form, as PostgreSQL, SQLite, DuckDB and MariaDB keep them.
private final class TwinCatalogDriver: PluginDriverStub, @unchecked Sendable {
    struct Calls: Equatable {
        var tables = 0
        var perTable = 0
        var bulk = 0
    }

    let names: [String]
    var providesBulkIndexFetch: Bool { true }
    var currentSchema: String? { "public" }
    private let recorded = OSAllocatedUnfairLock(initialState: Calls())

    init(names: [String] = [TwinNames.composed, TwinNames.decomposed, "orders"]) {
        self.names = names
    }

    var calls: Calls { recorded.withLock { $0 } }

    static func column(of table: String) -> String {
        "col_" + table.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private func requireNoTwins() throws {
        recorded.withLock { $0.bulk += 1 }
        guard !names.contains(where: { $0.utf8.elementsEqual(TwinNames.decomposed.utf8) }) else {
            throw PluginCatalogNameCollision(name: TwinNames.decomposed)
        }
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        recorded.withLock { $0.tables += 1 }
        return names.map { PluginTableInfo(name: $0, schema: schema, comment: nil) }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        recorded.withLock { $0.perTable += 1 }
        return [PluginColumnInfo(name: Self.column(of: table), dataType: "int")]
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        try requireNoTwins()
        return Dictionary(uniqueKeysWithValues: names.map { ($0, [PluginColumnInfo(name: Self.column(of: $0), dataType: "int")]) })
    }

    // Only the decomposed twin has a key, to the composed one, so a String lookup of the composed name finds it.
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        recorded.withLock { $0.perTable += 1 }
        guard table.utf8.elementsEqual(TwinNames.decomposed.utf8) else { return [] }
        return [PluginForeignKeyInfo(name: "fk", column: "id", referencedTable: TwinNames.composed, referencedColumn: "id")]
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        try requireNoTwins()
        return [:]
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        recorded.withLock { $0.perTable += 1 }
        guard table.utf8.elementsEqual(TwinNames.composed.utf8) else { return [] }
        return [PluginIndexInfo(name: "composed_pkey", columns: ["id"], isUnique: true, isPrimary: true)]
    }

    // A sparse answer: only the composed twin has an index, so the read sees one spelling and does not throw.
    func fetchAllIndexes(schema: String?) async throws -> [String: [PluginIndexInfo]] {
        recorded.withLock { $0.bulk += 1 }
        return [TwinNames.composed: [PluginIndexInfo(name: "composed_pkey", columns: ["id"], isUnique: true, isPrimary: true)]]
    }
}

@MainActor
struct PluginDriverAdapterTwinReadTests {
    private static func adapter(_ driver: TwinCatalogDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: driver)
    }

    @Test("A bulk column read that answers with two spellings of one name reads each table alone")
    func twinColumnsAreReadAlone() async throws {
        let driver = TwinCatalogDriver()

        let columns = try await Self.adapter(driver).fetchAllColumns()

        #expect(columns.count == 3)
        #expect(columns[CatalogName(TwinNames.composed)]?.map(\.name) == [TwinCatalogDriver.column(of: TwinNames.composed)])
        #expect(columns[CatalogName(TwinNames.decomposed)]?.map(\.name) == [TwinCatalogDriver.column(of: TwinNames.decomposed)])
        #expect(driver.calls == TwinCatalogDriver.Calls(tables: 1, perTable: 3, bulk: 1))
    }

    @Test("Without twins the bulk read stays one read")
    func plainSchemaStaysOneRead() async throws {
        let driver = TwinCatalogDriver(names: ["orders", "customers"])

        let columns = try await Self.adapter(driver).fetchAllColumns()
        let keys = try await Self.adapter(driver).fetchAllForeignKeys()

        #expect(columns.count == 2)
        #expect(keys.isEmpty)
        #expect(driver.calls == TwinCatalogDriver.Calls(tables: 0, perTable: 0, bulk: 2))
    }

    @Test("Foreign keys of twins stay with the twin that declares them")
    func twinForeignKeysAreReadAlone() async throws {
        let driver = TwinCatalogDriver()

        let keys = try await Self.adapter(driver).fetchAllForeignKeys()

        #expect(Array(keys.keys) == [CatalogName(TwinNames.decomposed)])
        #expect(keys[CatalogName(TwinNames.composed)] == nil)
        #expect(keys[CatalogName(TwinNames.decomposed)]?.first?.referencedTable.utf8.elementsEqual(TwinNames.composed.utf8) == true)
    }

    @Test("A sparse answer holding one twin answers nothing for the other")
    func sparseAnswerIsLookedUpByBytes() async throws {
        let driver = TwinCatalogDriver()
        let adapter = Self.adapter(driver)

        let entries = try await MCPConnectionBridge.indexEntries(using: adapter, schema: "public", table: nil)
        let tables = entries.compactMap { $0["table"]?.stringValue }

        #expect(tables.count == 1)
        #expect(tables.first?.utf8.elementsEqual(TwinNames.composed.utf8) == true)
    }
}
