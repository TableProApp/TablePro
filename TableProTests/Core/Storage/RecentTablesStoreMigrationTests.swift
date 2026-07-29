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
            at: Date(timeIntervalSince1970: 1)
        )
        #expect(store.entries(connectionId: conn).map(\.name) == ["orders"])
    }
}
