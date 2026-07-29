import Foundation
import Testing

@testable import TablePro

@Suite("RecentTablesStore")
@MainActor
struct RecentTablesStoreTests {
    private func makeStore() throws -> RecentTablesStore {
        let defaults = try #require(UserDefaults(suiteName: "RecentTablesTests.\(UUID().uuidString)"))
        return RecentTablesStore(defaults: defaults)
    }

    @Test("Record inserts entry at the front")
    func recordInsertsAtFront() throws {
        let store = try makeStore()
        let conn = UUID()
        store.record(connectionId: conn, database: "db", schema: nil, name: "a", isView: false)
        store.record(connectionId: conn, database: "db", schema: nil, name: "b", isView: false)
        #expect(store.entries(connectionId: conn).map(\.name) == ["b", "a"])
    }

    @Test("Record dedupes by identity and bumps to front")
    func recordDedupes() throws {
        let store = try makeStore()
        let conn = UUID()
        store.record(connectionId: conn, database: "db", schema: nil, name: "a", isView: false)
        store.record(connectionId: conn, database: "db", schema: nil, name: "b", isView: false)
        store.record(connectionId: conn, database: "db", schema: nil, name: "a", isView: false)
        #expect(store.entries(connectionId: conn).map(\.name) == ["a", "b"])
    }

    @Test("Record preserves the view flag")
    func recordPreservesViewFlag() throws {
        let store = try makeStore()
        let conn = UUID()
        store.record(connectionId: conn, database: "db", schema: nil, name: "orders_view", isView: true)
        #expect(store.entries(connectionId: conn).first?.isView == true)
    }

    @Test("Per-database list caps at 10 entries")
    func capsPerDatabase() throws {
        let store = try makeStore()
        let conn = UUID()
        for index in 0..<15 {
            store.record(connectionId: conn, database: "db", schema: nil, name: "t\(index)", isView: false)
        }
        let entries = store.entries(connectionId: conn).filter { $0.database == "db" }
        #expect(entries.count == 10)
        #expect(entries.first?.name == "t14")
        #expect(entries.last?.name == "t5")
    }

    @Test("Cap applies per database, not per connection")
    func capIsPerDatabase() throws {
        let store = try makeStore()
        let conn = UUID()
        for index in 0..<10 { store.record(connectionId: conn, database: "db", schema: nil, name: "d\(index)", isView: false) }
        for index in 0..<10 { store.record(connectionId: conn, database: "other", schema: nil, name: "o\(index)", isView: false) }
        #expect(store.entries(connectionId: conn).filter { $0.database == "db" }.count == 10)
        #expect(store.entries(connectionId: conn).filter { $0.database == "other" }.count == 10)
    }

    @Test("Entries isolated per connection")
    func isolatedPerConnection() throws {
        let store = try makeStore()
        let connA = UUID()
        let connB = UUID()
        store.record(connectionId: connA, database: "db", schema: nil, name: "alpha", isView: false)
        store.record(connectionId: connB, database: "db", schema: nil, name: "beta", isView: false)
        #expect(store.entries(connectionId: connA).map(\.name) == ["alpha"])
        #expect(store.entries(connectionId: connB).map(\.name) == ["beta"])
    }

    @Test("Schema-qualified table is distinct from same-name unqualified")
    func schemaDistinct() throws {
        let store = try makeStore()
        let conn = UUID()
        store.record(connectionId: conn, database: "db", schema: "public", name: "users", isView: false)
        store.record(connectionId: conn, database: "db", schema: nil, name: "users", isView: false)
        #expect(store.entries(connectionId: conn).count == 2)
    }

    @Test("Same name in different databases stays distinct")
    func databaseDistinct() throws {
        let store = try makeStore()
        let conn = UUID()
        store.record(connectionId: conn, database: "a", schema: nil, name: "orders", isView: false)
        store.record(connectionId: conn, database: "b", schema: nil, name: "orders", isView: false)
        #expect(store.entries(connectionId: conn).count == 2)
    }

    @Test("Dotted identifiers do not collide")
    func dottedIdentifiersDistinct() throws {
        let store = try makeStore()
        let conn = UUID()
        store.record(connectionId: conn, database: "db", schema: "a", name: "b.c", isView: false)
        store.record(connectionId: conn, database: "db", schema: "a.b", name: "c", isView: false)
        #expect(store.entries(connectionId: conn).count == 2)
    }

    @Test("Remove drops the matching entry")
    func removeDrops() throws {
        let store = try makeStore()
        let conn = UUID()
        store.record(connectionId: conn, database: "db", schema: nil, name: "a", isView: false)
        let remaining = store.record(connectionId: conn, database: "db", schema: nil, name: "b", isView: false)
        let target = try #require(remaining.first { $0.name == "a" })
        store.remove(connectionId: conn, entry: target)
        #expect(store.entries(connectionId: conn).map(\.name) == ["b"])
    }

    @Test("Clear removes only the given database")
    func clearScopesToDatabase() throws {
        let store = try makeStore()
        let conn = UUID()
        store.record(connectionId: conn, database: "db", schema: nil, name: "a", isView: false)
        store.record(connectionId: conn, database: "other", schema: nil, name: "b", isView: false)
        store.clear(connectionId: conn, database: "db")
        #expect(store.entries(connectionId: conn).map(\.name) == ["b"])
    }

    @Test("Entries persist across store instances on the same defaults")
    func persistsAcrossInstances() throws {
        let defaults = try #require(UserDefaults(suiteName: "RecentTablesTests.\(UUID().uuidString)"))
        let conn = UUID()
        RecentTablesStore(defaults: defaults).record(
            connectionId: conn, database: "db", schema: nil, name: "a", isView: false
        )
        let reopened = RecentTablesStore(defaults: defaults)
        #expect(reopened.entries(connectionId: conn).map(\.name) == ["a"])
    }
}
