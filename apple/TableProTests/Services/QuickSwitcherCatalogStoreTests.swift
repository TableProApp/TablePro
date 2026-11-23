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
    // One browse scope per case, so a lookup misses only on the field the case changes.
    private let browsedConnectionId = UUID()

    private func version(
        schemaGeneration: Int = 1,
        isRefreshing: Bool = false,
        databaseFilter: [String] = [],
        schemaFilter: [String] = [],
        contentRevision: Int = 0,
        containerNames: [String] = ["database:app"],
        sessionEpoch: Int = 0
    ) -> QuickSwitcherCatalogStore.Version {
        QuickSwitcherCatalogStore.Version(
            browseScope: DatabaseScope(connectionId: browsedConnectionId, database: "app", schema: "public"),
            schemaGeneration: schemaGeneration,
            isRefreshing: isRefreshing,
            databaseFilter: databaseFilter,
            schemaFilter: schemaFilter,
            contentRevision: contentRevision,
            containerNames: containerNames,
            sessionEpoch: sessionEpoch
        )
    }

    private func table(_ name: String, schema: String? = "public", isOpen: Bool = false) -> QuickSwitcherItem {
        QuickSwitcherItem(
            frecencyKey: QuickSwitcherFrecencyKey.table(
                name: name,
                schema: schema,
                in: .init(database: "app", connectionSwitchesDatabases: true)
            ),
            name: name,
            kind: .table,
            subtitle: "",
            isOpenInTab: isOpen,
            schemaName: schema
        )
    }

    private func database(_ name: String) -> QuickSwitcherItem {
        QuickSwitcherItem(frecencyKey: QuickSwitcherFrecencyKey.database(name), name: name, kind: .database, subtitle: "")
    }

    private func history(_ query: String) -> QuickSwitcherItem {
        QuickSwitcherItem(
            frecencyKey: QuickSwitcherFrecencyKey.queryHistory(query),
            name: query,
            kind: .queryHistory,
            subtitle: "",
            payload: query
        )
    }

    @Test("An unchanged version serves the stored catalog")
    func unchangedVersionHits() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        let key = version()
        store.storeContainers([table("users")], for: id, version: key)
        #expect(store.containers(for: id, version: key)?.map(\.name) == ["users"])
    }

    @Test("A moved schema generation misses")
    func movedSchemaGenerationMisses() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        store.storeContainers([table("users")], for: id, version: version(schemaGeneration: 1))
        #expect(store.containers(for: id, version: version(schemaGeneration: 2)) == nil)
    }

    @Test("A changed database filter misses")
    func changedDatabaseFilterMisses() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        store.storeContainers([table("users")], for: id, version: version(databaseFilter: ["app"]))
        #expect(store.containers(for: id, version: version(databaseFilter: ["app", "analytics"])) == nil)
    }

    @Test("A changed schema filter misses")
    func changedSchemaFilterMisses() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        store.storeContainers([table("users")], for: id, version: version(schemaFilter: ["sales"]))
        #expect(store.containers(for: id, version: version(schemaFilter: ["sales", "hr"])) == nil)
    }

    /// Favorites and query history change without the browse scope or the schema moving, so the
    /// revision is the only thing that can invalidate them.
    @Test("A bumped content revision misses the saved queries and history")
    func bumpedContentRevisionMissesContent() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        store.storeContent([history("select 1")], for: id, version: version(contentRevision: 0))
        #expect(store.content(for: id, version: version(contentRevision: 1)) == nil)
    }

    /// Opening a table records history, and that must not make the next open read the database
    /// and schema lists again.
    @Test("A bumped content revision keeps the containers")
    func bumpedContentRevisionKeepsContainers() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        store.storeContainers([database("app")], for: id, version: version(contentRevision: 0))
        #expect(store.containers(for: id, version: version(contentRevision: 1))?.map(\.name) == ["app"])
    }

    @Test("A recorded history entry keeps the containers and misses the history")
    func recordedHistoryKeepsContainers() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        let before = version(contentRevision: store.contentRevision(for: id))
        store.storeContainers([database("app")], for: id, version: before)
        store.storeContent([history("select 1")], for: id, version: before)

        AppEvents.shared.queryHistoryDidUpdate.send(id)

        let after = version(contentRevision: store.contentRevision(for: id))
        #expect(store.containers(for: id, version: after)?.map(\.name) == ["app"])
        #expect(store.content(for: id, version: after) == nil)
    }

    @Test("A dropped database misses the containers and keeps the history")
    func droppedDatabaseKeepsContent() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        let before = version(containerNames: ["database:app", "database:reporting_old"])
        store.storeContainers([database("app"), database("reporting_old")], for: id, version: before)
        store.storeContent([history("select 1")], for: id, version: before)

        let after = version(containerNames: ["database:app"])
        #expect(store.containers(for: id, version: after) == nil)
        #expect(store.content(for: id, version: after)?.map(\.payload) == ["select 1"])
    }

    @Test("A refreshing schema is a different version")
    func refreshingSchemaMisses() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        store.storeContainers([table("users")], for: id, version: version(isRefreshing: false))
        #expect(store.containers(for: id, version: version(isRefreshing: true)) == nil)
    }

    @Test("Another connection does not read this one's catalog")
    func otherConnectionMisses() {
        let store = QuickSwitcherCatalogStore()
        let key = version()
        store.storeContainers([table("users")], for: UUID(), version: key)
        #expect(store.containers(for: UUID(), version: key) == nil)
    }

    /// The reason the flag cannot be cached: the tabs move while none of the version's inputs do.
    @Test("Open-tab state is never stored")
    func openStateIsNotStored() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        let key = version()
        store.storeContainers([table("users", isOpen: true)], for: id, version: key)
        #expect(store.containers(for: id, version: key)?.first?.isOpenInTab == false)
    }

    /// The publishers send a nil connection id when the change was not scoped to one, and every
    /// connection the store knows about has to notice it, including one that has a cached catalog
    /// but has never had a revision recorded.
    @Test("An unscoped content change invalidates the history of every cached connection")
    func unscopedContentChangeInvalidatesAll() {
        let store = QuickSwitcherCatalogStore()
        let first = UUID()
        let second = UUID()
        store.storeContent([history("select 1")], for: first, version: version(contentRevision: 0))
        store.storeContent([history("select 2")], for: second, version: version(contentRevision: 0))

        AppEvents.shared.sqlFavoritesDidUpdate.send(nil)

        #expect(store.contentRevision(for: first) == 1)
        #expect(store.contentRevision(for: second) == 1)
        #expect(store.content(for: first, version: version(contentRevision: 1)) == nil)
        #expect(store.content(for: second, version: version(contentRevision: 1)) == nil)
    }

    @Test("An unscoped content change keeps the containers of every cached connection")
    func unscopedContentChangeKeepsContainers() {
        let store = QuickSwitcherCatalogStore()
        let first = UUID()
        let second = UUID()
        store.storeContainers([database("app")], for: first, version: version(contentRevision: 0))
        store.storeContainers([database("shop")], for: second, version: version(contentRevision: 0))

        AppEvents.shared.sqlFavoritesDidUpdate.send(nil)

        #expect(store.contentRevision(for: first) == 1)
        #expect(store.contentRevision(for: second) == 1)
        #expect(store.containers(for: first, version: version(contentRevision: 1))?.map(\.name) == ["app"])
        #expect(store.containers(for: second, version: version(contentRevision: 1))?.map(\.name) == ["shop"])
    }

    @Test("A scoped content change invalidates only that connection")
    func scopedContentChangeInvalidatesOne() {
        let store = QuickSwitcherCatalogStore()
        let target = UUID()
        let other = UUID()
        store.storeContainers([table("users")], for: target, version: version(contentRevision: 0))
        store.storeContainers([table("orders")], for: other, version: version(contentRevision: 0))

        AppEvents.shared.queryHistoryDidUpdate.send(target)

        #expect(store.contentRevision(for: target) == 1)
        #expect(store.contentRevision(for: other) == 0)
    }

    @Test("Removing a connection drops its catalog")
    func removeDropsCatalog() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        let key = version()
        store.storeContainers([table("users")], for: id, version: key)
        store.storeContent([history("select 1")], for: id, version: key)
        store.removeConnection(id)
        #expect(store.containers(for: id, version: key) == nil)
        #expect(store.content(for: id, version: key) == nil)
    }

    // MARK: - Container mutations

    /// Dropping a database refreshes the metadata service and moves nothing else in the key, so
    /// without the container names a dropped database stayed listed and committing it failed.
    @Test("A dropped database misses")
    func droppedDatabaseMisses() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        store.storeContainers([table("users")], for: id, version: version(containerNames: ["database:app", "database:reporting_old"]))
        #expect(store.containers(for: id, version: version(containerNames: ["database:app"])) == nil)
    }

    @Test("A created database misses")
    func createdDatabaseMisses() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        store.storeContainers([table("users")], for: id, version: version(containerNames: ["database:app"]))
        #expect(store.containers(for: id, version: version(containerNames: ["database:app", "database:staging"])) == nil)
    }

    @Test("A dropped schema misses")
    func droppedSchemaMisses() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        store.storeContainers([table("users")], for: id, version: version(containerNames: ["database:app", "schema:public", "schema:analytics"]))
        #expect(store.containers(for: id, version: version(containerNames: ["database:app", "schema:public"])) == nil)
    }

    /// The names are namespaced so dropping a database and creating a schema of the same name is
    /// not mistaken for no change at all.
    @Test("A database and a schema of the same name are distinguishable")
    func databaseAndSchemaNamesDoNotCollide() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        store.storeContainers([table("users")], for: id, version: version(containerNames: ["database:reporting"]))
        #expect(store.containers(for: id, version: version(containerNames: ["schema:reporting"])) == nil)
    }

    // MARK: - Session epoch

    /// A load still running when the session ends finishes and writes its catalog under the epoch
    /// it started with. Disconnecting resets the schema generation and the content revision, so
    /// without the epoch the reconnected session recomputes the same version and is served it.
    @Test("A catalog stored after the session ended is never served to the next one")
    func storeAfterRemoveIsNotServed() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        let beforeDisconnect = version(sessionEpoch: store.sessionEpoch(for: id))

        store.removeConnection(id)
        store.storeContainers([table("stale")], for: id, version: beforeDisconnect)
        store.storeContent([history("select stale")], for: id, version: beforeDisconnect)

        let afterReconnect = version(sessionEpoch: store.sessionEpoch(for: id))
        #expect(afterReconnect != beforeDisconnect)
        #expect(store.containers(for: id, version: afterReconnect) == nil)
        #expect(store.content(for: id, version: afterReconnect) == nil)
    }

    @Test("The session epoch survives removal so it keeps advancing")
    func sessionEpochSurvivesRemoval() {
        let store = QuickSwitcherCatalogStore()
        let id = UUID()
        #expect(store.sessionEpoch(for: id) == 0)
        store.removeConnection(id)
        #expect(store.sessionEpoch(for: id) == 1)
        store.removeConnection(id)
        #expect(store.sessionEpoch(for: id) == 2)
    }

    @Test("One connection's disconnect does not invalidate another's catalog")
    func epochIsPerConnection() {
        let store = QuickSwitcherCatalogStore()
        let kept = UUID()
        let dropped = UUID()
        let key = version()
        store.storeContainers([table("users")], for: kept, version: key)
        store.removeConnection(dropped)
        #expect(store.containers(for: kept, version: key)?.map(\.name) == ["users"])
    }
}
