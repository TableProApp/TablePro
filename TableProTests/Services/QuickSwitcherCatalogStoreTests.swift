//
//  QuickSwitcherCatalogStoreTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import Testing

@MainActor
struct QuickSwitcherCatalogStoreTests {
    private func version(
        schemaGeneration: Int = 1,
        isRefreshing: Bool = false,
        databaseFilter: [String] = [],
        contentRevision: Int = 0
    ) -> QuickSwitcherCatalogStore.Version {
        QuickSwitcherCatalogStore.Version(
            browseScope: DatabaseScope(connectionId: UUID(), database: "app", schema: "public"),
            schemaGeneration: schemaGeneration,
            isRefreshing: isRefreshing,
            databaseFilter: databaseFilter,
            contentRevision: contentRevision
        )
    }

    private func table(_ name: String, schema: String? = "public", isOpen: Bool = false) -> QuickSwitcherItem {
        QuickSwitcherItem(
            id: QuickSwitcherItem.tableItemId(name: name, schema: schema),
            name: name,
            kind: .table,
            subtitle: "",
            isOpenInTab: isOpen,
            schemaName: schema
        )
    }

    @Test("An unchanged version serves the stored catalog")
    func unchangedVersionHits() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        let key = version()
        store.store([table("users")], for: id, version: key)
        #expect(store.catalog(for: id, version: key)?.map(\.name) == ["users"])
    }

    @Test("A moved schema generation misses")
    func movedSchemaGenerationMisses() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        store.store([table("users")], for: id, version: version(schemaGeneration: 1))
        #expect(store.catalog(for: id, version: version(schemaGeneration: 2)) == nil)
    }

    @Test("A changed database filter misses")
    func changedDatabaseFilterMisses() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        store.store([table("users")], for: id, version: version(databaseFilter: ["app"]))
        #expect(store.catalog(for: id, version: version(databaseFilter: ["app", "analytics"])) == nil)
    }

    /// Favorites and query history change without the browse scope or the schema moving, so the
    /// revision is the only thing that can invalidate the catalog for them.
    @Test("A bumped content revision misses")
    func bumpedContentRevisionMisses() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        store.store([table("users")], for: id, version: version(contentRevision: 0))
        #expect(store.catalog(for: id, version: version(contentRevision: 1)) == nil)
    }

    @Test("A refreshing schema is a different version")
    func refreshingSchemaMisses() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        store.store([table("users")], for: id, version: version(isRefreshing: false))
        #expect(store.catalog(for: id, version: version(isRefreshing: true)) == nil)
    }

    @Test("Another connection does not read this one's catalog")
    func otherConnectionMisses() {
        let store = QuickSwitcherCatalogStore()
        let key = version()
        store.store([table("users")], for: UUID(), version: key)
        #expect(store.catalog(for: UUID(), version: key) == nil)
    }

    /// The reason the flag cannot be cached: the tabs move while none of the version's inputs do.
    @Test("Open-tab state is never stored")
    func openStateIsNotStored() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        let key = version()
        store.store([table("users", isOpen: true)], for: id, version: key)
        #expect(store.catalog(for: id, version: key)?.first?.isOpenInTab == false)
    }

    /// The publishers send a nil connection id when the change was not scoped to one, and every
    /// connection the store knows about has to notice it, including one that has a cached catalog
    /// but has never had a revision recorded.
    @Test("An unscoped content change invalidates every cached connection")
    func unscopedContentChangeInvalidatesAll() {
        let store = QuickSwitcherCatalogStore()
        let first = UUID()
        let second = UUID()
        store.store([table("users")], for: first, version: version(contentRevision: 0))
        store.store([table("orders")], for: second, version: version(contentRevision: 0))

        AppEvents.shared.sqlFavoritesDidUpdate.send(nil)

        #expect(store.contentRevision(for: first) == 1)
        #expect(store.contentRevision(for: second) == 1)
    }

    @Test("A scoped content change invalidates only that connection")
    func scopedContentChangeInvalidatesOne() {
        let store = QuickSwitcherCatalogStore()
        let target = UUID()
        let other = UUID()
        store.store([table("users")], for: target, version: version(contentRevision: 0))
        store.store([table("orders")], for: other, version: version(contentRevision: 0))

        AppEvents.shared.queryHistoryDidUpdate.send(target)

        #expect(store.contentRevision(for: target) == 1)
        #expect(store.contentRevision(for: other) == 0)
    }

    @Test("Removing a connection drops its catalog")
    func removeDropsCatalog() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        let key = version()
        store.store([table("users")], for: id, version: key)
        store.removeConnection(id)
        #expect(store.catalog(for: id, version: key) == nil)
    }

    // MARK: - Open state applied on read

    @Test("Open state is applied to a cached catalog on the way out")
    func openStateAppliedOnRead() {
        let openTables: Set<QuickSwitcherOpenTable> = [
            QuickSwitcherOpenTable(schema: "public", name: "users", browsing: "public")
        ]
        let applied = QuickSwitcherViewModel.applyingOpenState(
            to: [table("users"), table("orders")],
            openTables: openTables,
            browsing: "public"
        )
        #expect(applied.first { $0.name == "users" }?.isOpenInTab == true)
        #expect(applied.first { $0.name == "orders" }?.isOpenInTab == false)
    }

    /// The same defect #2191 fixed, reached through the cache instead of a fresh load.
    @Test("A table of the same name in another schema is not badged from the cache")
    func openStateRespectsSchemaOnRead() {
        let openTables: Set<QuickSwitcherOpenTable> = [
            QuickSwitcherOpenTable(schema: "public", name: "users", browsing: "analytics")
        ]
        let applied = QuickSwitcherViewModel.applyingOpenState(
            to: [table("users", schema: "analytics")],
            openTables: openTables,
            browsing: "analytics"
        )
        #expect(applied.first?.isOpenInTab == false)
    }

    /// The function is unconditionally authoritative rather than skipping an empty set, so a badge
    /// can never survive from whatever it was handed.
    @Test("No open tabs clears the badge on every row")
    func noOpenTabsClearsBadge() {
        let applied = QuickSwitcherViewModel.applyingOpenState(
            to: [table("users", isOpen: true)],
            openTables: [],
            browsing: "public"
        )
        #expect(applied.first?.isOpenInTab == false)
    }
}
