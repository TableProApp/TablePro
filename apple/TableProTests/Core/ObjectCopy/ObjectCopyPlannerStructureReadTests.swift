//
//  ObjectCopyPlannerStructureReadTests.swift
//  TableProTests
//
//  What reading the source costs before the review shows. A selection of
//  every table takes the whole-schema reads; a strict subset keeps the
//  per-table ones.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class BulkReadCountingDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private let listed: [PluginTableInfo]

    init(_ names: [String]) {
        listed = names.map { PluginTableInfo(name: $0, type: "TABLE", schema: nil, comment: nil) }
    }

    var calls: [String] { lock.withLock { log } }

    private func record(_ call: String) {
        lock.withLock { log.append(call) }
    }

    private var column: [PluginColumnInfo] { [PluginColumnInfo(name: "id", dataType: "int")] }

    var providesBulkColumnFetch: Bool { true }
    var providesBulkIndexFetch: Bool { true }
    var providesBulkForeignKeyFetch: Bool { true }
    var providesBulkTableMetadataFetch: Bool { true }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { listed }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        record("fetchAllColumns")
        return Dictionary(uniqueKeysWithValues: listed.map { ($0.name, column) })
    }

    func fetchAllIndexes(schema: String?) async throws -> [String: [PluginIndexInfo]] {
        record("fetchAllIndexes")
        return [:]
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        record("fetchAllForeignKeys")
        return [:]
    }

    func fetchAllTableMetadata(schema: String?) async throws -> [String: PluginTableMetadata] {
        record("fetchAllTableMetadata")
        return [:]
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        record("fetchColumns \(table)")
        return column
    }
}

struct ObjectCopyPlannerStructureReadTests {
    /// Every name handed over, in another case than the server's, still covers the scope.
    @Test
    func aSelectionOfEveryTableReadsTheWholeSchema() async throws {
        let driver = BulkReadCountingDriver(["estates", "buildings", "users"])

        let read = try await ObjectCopyPlanner.pinnedTableReads(
            names: ["Estates", "buildings", "users"], schema: nil, databaseType: .mysql, using: driver
        )

        #expect(read.reads.map(\.table.name) == ["estates", "buildings", "users"])
        #expect(driver.calls.filter { $0 == "fetchAllColumns" }.count == 1)
        #expect(!driver.calls.contains { $0.hasPrefix("fetchColumns") })
    }

    @Test
    func aStrictSubsetKeepsThePerTableReads() async throws {
        let driver = BulkReadCountingDriver(["estates", "buildings", "users"])

        let read = try await ObjectCopyPlanner.pinnedTableReads(
            names: ["estates"], schema: nil, databaseType: .mysql, using: driver
        )

        #expect(read.reads.map(\.table.name) == ["estates"])
        #expect(!driver.calls.contains("fetchAllColumns"))
        #expect(driver.calls.contains("fetchColumns estates"))
        #expect(!driver.calls.contains("fetchColumns users"))
    }

    /// A copy never offers a foreign table or a sequence, and leaving a view out costs a bulk read
    /// little, so none of them makes the selection a subset.
    @Test
    func onlyATableLeftOutNarrowsTheRead() {
        let listed = [
            PluginTableInfo(name: "orders", type: "TABLE", schema: nil, comment: nil),
            PluginTableInfo(name: "recent", type: "VIEW", schema: nil, comment: nil),
            PluginTableInfo(name: "remote", type: "FOREIGN TABLE", schema: nil, comment: nil),
            PluginTableInfo(name: "orders_id_seq", type: "SEQUENCE", schema: nil, comment: nil)
        ]

        #expect(!CompareMetadataService.narrows(listed, to: ["orders"]))
        #expect(CompareMetadataService.narrows(listed, to: ["recent"]))
        #expect(!CompareMetadataService.narrows(listed, to: nil), "a comparison names nothing and reads the scope")
    }
}
