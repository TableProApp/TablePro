//
//  ForeignKeysForTablesReadTests.swift
//  TableProTests
//
//  Asking for six tables' foreign keys on a driver without a bulk read fell into the schema-wide
//  default, one round trip per table in the schema, and a cancelled caller kept the loop going.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class CatalogReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var tables: [String] = []
    private var listings = 0
    private var bulk = 0

    var perTableReads: [String] { lock.withLock { tables } }
    var tableListings: Int { lock.withLock { listings } }
    var bulkReads: Int { lock.withLock { bulk } }

    func recordTable(_ name: String) { lock.withLock { tables.append(name) } }
    func recordListing() { lock.withLock { listings += 1 } }
    func recordBulk() { lock.withLock { bulk += 1 } }
}

private func foreignKey(on table: String) -> PluginForeignKeyInfo {
    PluginForeignKeyInfo(
        name: "fk_\(table)", column: "parent_id", referencedTable: "parent", referencedColumn: "id",
        referencedDatabase: nil
    )
}

private func tableInfos(_ count: Int) -> [PluginTableInfo] {
    (0..<count).map {
        PluginTableInfo(name: "t\($0)", comment: nil, partitionCount: nil, ownedByTable: nil, ownedByColumn: nil)
    }
}

// No bulk query of its own, so its schema-wide read is PluginKit's per-table default.
private final class PerTableCatalogDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { "public" }
    var serverVersion: String? { nil }

    let log = CatalogReadLog()
    private let tableCount: Int
    private let failures: [String: any Error]
    private let cancelsCallerOnRead: Bool

    init(tableCount: Int, failures: [String: any Error] = [:], cancelsCallerOnRead: Bool = false) {
        self.tableCount = tableCount
        self.failures = failures
        self.cancelsCallerOnRead = cancelsCallerOnRead
    }

    func ping() async throws {}

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        log.recordListing()
        return tableInfos(tableCount)
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        log.recordTable(table)
        if cancelsCallerOnRead { withUnsafeCurrentTask { $0?.cancel() } }
        if let failure = failures[table] { throw failure }
        return [foreignKey(on: table)]
    }
}

private final class BulkCatalogDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { "public" }
    var serverVersion: String? { nil }
    var providesBulkForeignKeyFetch: Bool { true }

    let log = CatalogReadLog()
    private let tableCount: Int

    init(tableCount: Int) {
        self.tableCount = tableCount
    }

    func ping() async throws {}

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        log.recordTable(table)
        return [foreignKey(on: table)]
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        log.recordBulk()
        return Dictionary(uniqueKeysWithValues: tableInfos(tableCount).map { ($0.name, [foreignKey(on: $0.name)]) })
    }
}

struct ForeignKeysForTablesReadTests {
    private let sixTables = (0..<6).map { "t\($0)" }

    private func adapter(_ driver: any PluginDatabaseDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: DatabaseConnection(name: "Test", type: .postgresql), pluginDriver: driver)
    }

    @Test("Six tables on a driver without a bulk read cost six reads, not one per table in the schema")
    func perTableDriverReadsOnlyTheTablesAskedFor() async throws {
        let driver = PerTableCatalogDriver(tableCount: 500)

        let keys = try await adapter(driver).fetchForeignKeys(forTables: sixTables)

        #expect(driver.log.perTableReads == sixTables)
        #expect(driver.log.tableListings == 0)
        #expect(Set(keys.keys) == Set(sixTables))
        #expect(keys["t3"]?.first?.name == "fk_t3")
    }

    @Test("A driver with a bulk read still answers more than five tables from one query")
    func bulkDriverKeepsItsSingleQuery() async throws {
        let driver = BulkCatalogDriver(tableCount: 500)

        let keys = try await adapter(driver).fetchForeignKeys(forTables: sixTables)

        #expect(driver.log.bulkReads == 1)
        #expect(driver.log.perTableReads.isEmpty)
        #expect(Set(keys.keys) == Set(sixTables))
    }

    @Test("Past five tables without a bulk read, a table that cannot be read still fails the read")
    func perTableDriverPastFiveStillFails() async {
        let driver = PerTableCatalogDriver(tableCount: 500, failures: ["t2": DatabaseError.queryFailed("denied")])

        await #expect(throws: DatabaseError.self) {
            _ = try await adapter(driver).fetchForeignKeys(forTables: sixTables)
        }
        #expect(driver.log.perTableReads == ["t0", "t1", "t2"])
    }

    @Test("Up to five tables, a table that cannot be read is left out and the rest are returned")
    func smallSetSkipsAnUnreadableTable() async throws {
        let driver = PerTableCatalogDriver(tableCount: 500, failures: ["t1": DatabaseError.queryFailed("denied")])

        let keys = try await adapter(driver).fetchForeignKeys(forTables: ["t0", "t1", "t2"])

        #expect(Set(keys.keys) == ["t0", "t2"])
    }

    @Test("A cancelled caller stops the per-table read at the next table")
    func cancelledCallerStopsTheLoop() async {
        let driver = PerTableCatalogDriver(tableCount: 500, cancelsCallerOnRead: true)
        let reader = adapter(driver)

        let read = Task { try await reader.fetchForeignKeys(forTables: ["t0", "t1", "t2"]) }
        await #expect(throws: CancellationError.self) {
            _ = try await read.value
        }
        #expect(driver.log.perTableReads == ["t0"])
    }

    @Test("A table read that reports a cancellation ends the read instead of being skipped")
    func cancellationFromTheDriverIsNotSkipped() async {
        let driver = PerTableCatalogDriver(tableCount: 500, failures: ["t0": CancellationError()])

        await #expect(throws: CancellationError.self) {
            _ = try await adapter(driver).fetchForeignKeys(forTables: ["t0", "t1", "t2"])
        }
        #expect(driver.log.perTableReads == ["t0"])
    }
}
