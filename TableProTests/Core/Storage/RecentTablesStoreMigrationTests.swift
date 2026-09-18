//
//  RecentTablesStoreMigrationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("RecentTablesStore migration")
@MainActor
struct RecentTablesStoreMigrationTests {
    @Test("Migrates the legacy RecentTables.v1 key to the namespaced key")
    func migratesLegacyKey() throws {
        let defaults = try #require(UserDefaults(suiteName: "recent-\(UUID().uuidString)"))
        let store = RecentTablesStore(defaults: defaults)
        let conn = UUID()
        let entry = RecentTableEntry(
            database: "shop",
            schema: "public",
            name: "orders",
            isView: false,
            objectType: nil,
            openedAt: Date(timeIntervalSince1970: 100)
        )
        let legacyKey = "RecentTables.v1.\(conn.uuidString)"
        defaults.set(try JSONEncoder().encode([entry]), forKey: legacyKey)

        #expect(store.entries(connectionId: conn) == [entry])
        #expect(defaults.data(forKey: legacyKey) == nil)
        #expect(defaults.data(forKey: PreferenceKeys.recentTables(connectionId: conn).name) != nil)
    }

    @Test("Records and reads through the namespaced key")
    func recordRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "recent-\(UUID().uuidString)"))
        let store = RecentTablesStore(defaults: defaults)
        let conn = UUID()
        store.record(
            connectionId: conn,
            database: "shop",
            schema: "public",
            name: "orders",
            isView: false,
            objectType: .table,
            at: Date(timeIntervalSince1970: 1)
        )
        #expect(store.entries(connectionId: conn).map(\.name) == ["orders"])
    }

    /// An entry written before the kind was recorded carries no `objectType` key at all, and has to
    /// keep opening the way it always did rather than failing the decode of the whole file.
    @Test("An entry stored without a kind still decodes and reads as a table or a view")
    func entriesWithoutAKindStillDecode() throws {
        let stored = """
            [
              {"database":"shop","schema":"public","name":"orders","isView":false,"openedAt":100},
              {"database":"shop","schema":"public","name":"recent","isView":true,"openedAt":99}
            ]
            """
        let data = try #require(stored.data(using: .utf8))
        let entries = try JSONDecoder().decode([RecentTableEntry].self, from: data)

        #expect(entries.allSatisfy { $0.objectType == nil })
        #expect(entries.map(\.tableInfo.type) == [.table, .view])
    }

    /// Measured on MariaDB 11.4.13: `DROP VIEW` on a sequence fails with ERROR 4092. A Recent row
    /// recorded through `isView` alone said "Drop View" and issued one.
    @Test("A recorded kind is what the Recent row opens as")
    func recordedKindSurvivesARoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "recent-\(UUID().uuidString)"))
        let store = RecentTablesStore(defaults: defaults)
        let conn = UUID()
        store.record(
            connectionId: conn,
            database: "app",
            schema: nil,
            name: "order_ids",
            isView: true,
            objectType: .sequence
        )

        #expect(store.entries(connectionId: conn).first?.tableInfo.type == .sequence)
    }
}
