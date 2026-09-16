//
//  RecentTablesStoreSchemaClearTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// Dropping a schema used to leave its Recent entries behind, so every one of them opened a tab
/// whose query failed with "relation does not exist", and they survived a reconnect and a restart
/// because they persist per connection in UserDefaults.
@Suite("RecentTablesStore schema clear")
@MainActor
struct RecentTablesStoreSchemaClearTests {
    private func entry(database: String?, schema: String?, name: String) -> RecentTableEntry {
        RecentTableEntry(
            database: database,
            schema: schema,
            name: name,
            isView: false,
            openedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func seed(_ store: RecentTablesStore, connectionId: UUID, _ entries: [RecentTableEntry]) {
        for entry in entries.reversed() {
            store.record(
                connectionId: connectionId,
                database: entry.database,
                schema: entry.schema,
                name: entry.name,
                isView: entry.isView,
                at: entry.openedAt
            )
        }
    }

    @Test("Clearing one schema removes only its entries")
    func clearsOnlyTheNamedSchema() throws {
        let defaults = try #require(UserDefaults(suiteName: "recent-\(UUID().uuidString)"))
        let store = RecentTablesStore(defaults: defaults)
        let conn = UUID()
        seed(store, connectionId: conn, [
            entry(database: "shop", schema: "app_data", name: "orders"),
            entry(database: "shop", schema: "app_data", name: "invoices"),
            entry(database: "shop", schema: "public", name: "users")
        ])

        let remaining = store.clear(connectionId: conn, database: "shop", schema: "app_data")

        #expect(remaining.map(\.name) == ["users"])
        #expect(store.entries(connectionId: conn).map(\.name) == ["users"])
    }

    @Test("A same-named schema in another database keeps its entries")
    func leavesOtherDatabasesAlone() throws {
        let defaults = try #require(UserDefaults(suiteName: "recent-\(UUID().uuidString)"))
        let store = RecentTablesStore(defaults: defaults)
        let conn = UUID()
        seed(store, connectionId: conn, [
            entry(database: "shop", schema: "app_data", name: "orders"),
            entry(database: "warehouse", schema: "app_data", name: "orders")
        ])

        let remaining = store.clear(connectionId: conn, database: "shop", schema: "app_data")

        #expect(remaining.map(\.database) == ["warehouse"])
    }

    @Test("Clearing a schema nothing was opened in changes nothing")
    func clearingAnUnusedSchemaIsANoOp() throws {
        let defaults = try #require(UserDefaults(suiteName: "recent-\(UUID().uuidString)"))
        let store = RecentTablesStore(defaults: defaults)
        let conn = UUID()
        seed(store, connectionId: conn, [entry(database: "shop", schema: "public", name: "users")])

        let remaining = store.clear(connectionId: conn, database: "shop", schema: "reporting")

        #expect(remaining.map(\.name) == ["users"])
    }
}
