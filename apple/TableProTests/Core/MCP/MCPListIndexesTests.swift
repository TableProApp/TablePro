//
//  MCPListIndexesTests.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import TableProMCP
import TableProPluginKit
import Testing

@MainActor
struct MCPListIndexesTests {
    private static let expected = ["customers: customers_email, customers_pkey", "orders: orders_pkey"]

    private static func entries(
        _ driver: IndexListingDriver,
        table: String? = nil
    ) async throws -> [String] {
        let adapter = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: driver)
        let entries = try await MCPConnectionBridge.indexEntries(using: adapter, schema: "public", table: table)
        return entries.map { entry in
            let names = entry["indexes"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
            return "\(entry["table"]?.stringValue ?? "?"): \(names.joined(separator: ", "))"
        }
    }

    @Test("Without a table, a driver with a bulk index read answers in one query instead of one per table")
    func bulkReadReplacesPerTableReads() async throws {
        let driver = IndexListingDriver(providesBulkIndexFetch: true)
        #expect(try await Self.entries(driver) == Self.expected)
        #expect(driver.calls == IndexListingDriver.Calls(perTable: 0, bulk: 1))
    }

    @Test("A driver without a bulk read lists the same indexes one table at a time")
    func perTableReadsWithoutBulkRead() async throws {
        let driver = IndexListingDriver(providesBulkIndexFetch: false)
        #expect(try await Self.entries(driver) == Self.expected)
        #expect(driver.calls == IndexListingDriver.Calls(perTable: 3, bulk: 0))
    }

    @Test("A bulk read that fails falls back to the per-table reads")
    func failedBulkReadFallsBack() async throws {
        let driver = IndexListingDriver(providesBulkIndexFetch: true, bulkError: URLError(.timedOut))
        #expect(try await Self.entries(driver) == Self.expected)
        #expect(driver.calls == IndexListingDriver.Calls(perTable: 3, bulk: 1))
    }

    @Test("A named table reads that table's indexes only")
    func namedTableSkipsTheBulkRead() async throws {
        let driver = IndexListingDriver(providesBulkIndexFetch: true)
        #expect(try await Self.entries(driver, table: "orders") == ["orders: orders_pkey"])
        #expect(driver.calls == IndexListingDriver.Calls(perTable: 1, bulk: 0))
    }
}

private final class IndexListingDriver: PluginDriverStub, @unchecked Sendable {
    struct Calls: Equatable {
        var perTable = 0
        var bulk = 0
    }

    let providesBulkIndexFetch: Bool
    private let bulkError: Error?
    private let recorded = OSAllocatedUnfairLock(initialState: Calls())
    private let indexes: [String: [PluginIndexInfo]] = [
        "orders": [PluginIndexInfo(name: "orders_pkey", columns: ["id"], isUnique: true, isPrimary: true)],
        "customers": [
            PluginIndexInfo(name: "customers_email", columns: ["email"], isUnique: true),
            PluginIndexInfo(name: "customers_pkey", columns: ["id"], isUnique: true, isPrimary: true)
        ]
    ]

    init(providesBulkIndexFetch: Bool, bulkError: Error? = nil) {
        self.providesBulkIndexFetch = providesBulkIndexFetch
        self.bulkError = bulkError
    }

    var calls: Calls { recorded.withLock { $0 } }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        ["orders", "customers", "audit_log"].map { PluginTableInfo(name: $0, comment: nil, partitionCount: nil) }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        recorded.withLock { $0.perTable += 1 }
        return indexes[table] ?? []
    }

    func fetchAllIndexes(schema: String?) async throws -> [String: [PluginIndexInfo]] {
        recorded.withLock { $0.bulk += 1 }
        if let bulkError { throw bulkError }
        return indexes
    }
}
