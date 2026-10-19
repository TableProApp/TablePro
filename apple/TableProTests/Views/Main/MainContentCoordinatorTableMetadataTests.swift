//
//  MainContentCoordinatorTableMetadataTests.swift
//  TableProTests
//

import AppKit
import Combine
import Foundation
import SwiftUI
import TableProEditorKit
import TableProPluginKit
import TableProTestSupport
import Testing

@testable import TablePro

@MainActor
struct MainContentCoordinatorTableMetadataTests {
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        return (coordinator, tabManager)
    }

    /// Stamped by default, the way a tab looks once its rows have arrived. The bug this suite guards
    /// lives in the moment before that, so the cases about it pass `executedAt: nil`.
    private func addTableTab(
        to tabManager: QueryTabManager,
        tableName: String,
        database: String = "",
        executedAt: Date? = Date()
    ) -> QueryTab {
        var tab = QueryTab(
            title: tableName,
            query: "SELECT * FROM \(tableName)",
            tabType: .table,
            tableName: tableName
        )
        tab.tableContext.databaseName = database
        tab.execution.lastExecutedAt = executedAt
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab
    }

    private func metadata(_ tableName: String, rowCount: Int64 = 0, comment: String? = nil) -> TableMetadata {
        TableMetadata(
            tableName: tableName,
            dataSize: nil,
            indexSize: nil,
            totalSize: nil,
            avgRowLength: nil,
            rowCount: rowCount,
            comment: comment,
            engine: nil,
            collation: nil,
            createTime: nil,
            updateTime: nil
        )
    }

    private func cache(_ metadata: TableMetadata, for tab: QueryTab, in coordinator: MainContentCoordinator) throws {
        let table = try #require(coordinator.tableInfoIdentity(of: tab))
        coordinator.tableMetadataCache[tab.id] = TableMetadataCacheEntry(
            table: table,
            lastExecutedAt: tab.execution.lastExecutedAt,
            generation: coordinator.tableMetadataGeneration,
            metadata: metadata
        )
    }

    private func liveTab(_ id: UUID, in tabManager: QueryTabManager) throws -> QueryTab {
        try #require(tabManager.tabs.first { $0.id == id })
    }

    // MARK: - The cache

    @Test("Alternating between two tables fetches once per table, not once per switch")
    func alternatingTabsHitTheCache() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let orders = addTableTab(to: tabManager, tableName: "orders")
        let customers = addTableTab(to: tabManager, tableName: "customers")

        #expect(!coordinator.hasCurrentTableMetadata(for: orders))
        try cache(metadata("orders", rowCount: 10), for: orders, in: coordinator)
        try cache(metadata("customers", rowCount: 20), for: customers, in: coordinator)

        #expect(coordinator.hasCurrentTableMetadata(for: orders))
        #expect(coordinator.hasCurrentTableMetadata(for: customers))
    }

    @Test("A table of the same name in another database never shows the other one's numbers")
    func sameNameInAnotherDatabaseIsNotShown() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tenantA = addTableTab(to: tabManager, tableName: "orders", database: "tenant_a")
        let tenantB = addTableTab(to: tabManager, tableName: "orders", database: "tenant_b")
        let tenantAMetadata = metadata("orders", rowCount: 10)
        try cache(tenantAMetadata, for: tenantA, in: coordinator)

        var retargeted = tenantA
        retargeted.tableContext.databaseName = "tenant_b"

        #expect(coordinator.currentTableMetadata(for: tenantA) == tenantAMetadata)
        #expect(coordinator.currentTableMetadata(for: tenantB) == nil)
        #expect(coordinator.currentTableMetadata(for: retargeted) == nil)
    }

    /// A refresh never clears what it refreshes: the panel keeps the last numbers until new ones
    /// arrive, while the cache reports them stale so the next load refetches.
    @Test("Re-running the tab's query keeps its numbers on screen and makes them stale")
    func reExecutingKeepsTheShownNumbers() throws {
        let (coordinator, tabManager) = makeCoordinator()
        var orders = addTableTab(to: tabManager, tableName: "orders")
        let shown = metadata("orders", rowCount: 10)
        try cache(shown, for: orders, in: coordinator)

        orders.execution.lastExecutedAt = Date(timeIntervalSince1970: 1)

        #expect(coordinator.currentTableMetadata(for: orders) == shown)
        #expect(!coordinator.hasCurrentTableMetadata(for: orders))
    }

    @Test("Retargeting a tab to another table hides and invalidates its cached numbers")
    func retargetingInvalidatesTheEntry() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let orders = addTableTab(to: tabManager, tableName: "orders")
        try cache(metadata("orders", rowCount: 10), for: orders, in: coordinator)

        var retargeted = orders
        retargeted.tableContext.tableName = "customers"

        #expect(!coordinator.hasCurrentTableMetadata(for: retargeted))
        #expect(coordinator.currentTableMetadata(for: retargeted) == nil)
    }

    /// The docs say a tab with no table of its own, such as a query, leaves Table Info empty. A
    /// query tab can still carry the name of the table its result came from.
    @Test("A query tab has no Table Info, whatever table its result came from")
    func queryTabHasNoTableInfo() {
        let (coordinator, tabManager) = makeCoordinator()
        var query = QueryTab(title: "Query", query: "SELECT * FROM orders", tabType: .query, tableName: "orders")
        query.execution.lastExecutedAt = Date()
        tabManager.tabs.append(query)

        #expect(coordinator.tableInfoIdentity(of: query) == nil)
        #expect(coordinator.currentTableMetadata(for: query) == nil)
    }

    @Test("Closed tabs take their cached numbers with them")
    func closingATabPrunesTheEntry() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let orders = addTableTab(to: tabManager, tableName: "orders")
        let customers = addTableTab(to: tabManager, tableName: "customers")
        try cache(metadata("orders", rowCount: 10), for: orders, in: coordinator)
        try cache(metadata("customers", rowCount: 20), for: customers, in: coordinator)

        coordinator.cleanupTabCaches(openTabIds: [customers.id])
        #expect(coordinator.tableMetadataCache[orders.id] == nil)
        #expect(coordinator.tableMetadataCache[customers.id] != nil)
    }

    /// The inspector rebuilds its snapshot from a trigger that reads the cache, so a write the
    /// coordinator does not announce never reaches the panel. A comment refetch did exactly that.
    @Test("A write to the cache is announced to the views that observe the coordinator")
    func cacheWritesArePublished() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let orders = addTableTab(to: tabManager, tableName: "orders")
        var announcements = 0
        let subscription = coordinator.$tableMetadataCache.dropFirst().sink { _ in announcements += 1 }
        defer { subscription.cancel() }

        try cache(metadata("orders"), for: orders, in: coordinator)

        #expect(announcements == 1)
    }

    // MARK: - Loading

    @Test("Table Info waits for the tab's rows, then reads once they arrive")
    func loadWaitsForTheRows() async throws {
        let session = LiveSession()
        defer { session.tearDown() }
        let opened = addTableTab(to: session.tabManager, tableName: "orders", executedAt: nil)
        session.paneState.inspector.setOnScreen(true)

        await session.coordinator.loadTableMetadata(for: opened)
        #expect(session.driver.fetchTableMetadataCalls.isEmpty)

        var loaded = opened
        loaded.execution.lastExecutedAt = Date()
        session.tabManager.updateTab(loaded)
        await session.coordinator.loadTableMetadata(for: loaded)

        #expect(session.driver.fetchTableMetadataCalls == ["orders"])
        #expect(session.coordinator.currentTableMetadata(for: loaded)?.tableName == "orders")
    }

    @Test("Table Info reads nothing while the inspector is off screen")
    func offScreenInspectorReadsNothing() async {
        let session = LiveSession()
        defer { session.tearDown() }
        let orders = addTableTab(to: session.tabManager, tableName: "orders")

        await session.coordinator.loadTableMetadata(for: orders)

        #expect(session.driver.fetchTableMetadataCalls.isEmpty)
        #expect(session.coordinator.currentTableMetadata(for: orders) == nil)
    }

    @Test("A query tab never reads Table Info")
    func queryTabReadsNothing() async {
        let session = LiveSession()
        defer { session.tearDown() }
        var query = QueryTab(title: "Query", query: "SELECT * FROM orders", tabType: .query, tableName: "orders")
        query.execution.lastExecutedAt = Date()
        session.tabManager.tabs.append(query)
        session.tabManager.selectedTabId = query.id
        session.paneState.inspector.setOnScreen(true)

        await session.coordinator.loadTableMetadata(for: query)

        #expect(session.driver.fetchTableMetadataCalls.isEmpty)
    }

    @Test("A cached entry answers without reaching the database")
    func cachedEntryAnswersWithoutAFetch() async throws {
        let session = LiveSession()
        defer { session.tearDown() }
        let orders = addTableTab(to: session.tabManager, tableName: "orders")
        session.paneState.inspector.setOnScreen(true)
        let cached = metadata("orders", rowCount: 42)
        try cache(cached, for: orders, in: session.coordinator)

        await session.coordinator.loadTableMetadata(for: orders)

        #expect(session.driver.fetchTableMetadataCalls.isEmpty)
        #expect(session.coordinator.currentTableMetadata(for: orders) == cached)
    }

    /// The read cannot be cancelled. Landing after the preview tab moved onto the same name in
    /// another schema, it used to be stored and shown under the table the tab moved to.
    @Test("A read that lands after its tab moved to another table is dropped")
    func lateReadAfterARetargetIsDropped() async throws {
        let session = LiveSession()
        defer { session.tearDown() }
        let sales = addTableTab(to: session.tabManager, tableName: "orders")
        session.paneState.inspector.setOnScreen(true)
        session.driver.pausesNextFetchTableMetadata = true

        let read = Task { await session.coordinator.loadTableMetadata(for: sales) }
        try await waitUntil { session.driver.fetchTableMetadataCalls.count == 1 }
        let retargeted = try session.tabManager.replaceTabContent(
            tableName: "orders",
            databaseType: session.connection.type,
            schemaName: "archive"
        )
        try #require(retargeted)
        var archive = try liveTab(sales.id, in: session.tabManager)
        archive.execution.lastExecutedAt = Date(timeIntervalSinceNow: 60)
        session.tabManager.updateTab(archive)
        session.driver.resumeFetchTableMetadata()
        await read.value

        #expect(session.coordinator.tableMetadataCache[sales.id] == nil)
        #expect(session.coordinator.currentTableMetadata(for: archive) == nil)
    }

    /// The same table under another identity on the same id, with no run in between, as a schema
    /// that resolves after the read started. The identity alone has to drop it.
    @Test("A read that lands after its tab's identity changed is dropped, whatever the stamp")
    func lateReadAfterAnIdentityChangeIsDropped() async throws {
        let session = LiveSession()
        defer { session.tearDown() }
        let orders = addTableTab(to: session.tabManager, tableName: "orders")
        session.paneState.inspector.setOnScreen(true)
        session.driver.pausesNextFetchTableMetadata = true

        let read = Task { await session.coordinator.loadTableMetadata(for: orders) }
        try await waitUntil { session.driver.fetchTableMetadataCalls.count == 1 }
        var moved = try liveTab(orders.id, in: session.tabManager)
        moved.tableContext.schemaName = "archive"
        session.tabManager.updateTab(moved)
        session.driver.resumeFetchTableMetadata()
        await read.value

        #expect(session.coordinator.tableMetadataCache[orders.id] == nil)
    }

    /// The load key does not move on a page, so a read dropped here would never run again and the
    /// panel would stay empty: the reported bug by another route.
    @Test("A read that lands after its tab ran again is kept, stamped with the run it was read for")
    func lateReadAfterARerunIsKept() async throws {
        let session = LiveSession()
        defer { session.tearDown() }
        let orders = addTableTab(to: session.tabManager, tableName: "orders")
        session.paneState.inspector.setOnScreen(true)
        session.driver.pausesNextFetchTableMetadata = true

        let read = Task { await session.coordinator.loadTableMetadata(for: orders) }
        try await waitUntil { session.driver.fetchTableMetadataCalls.count == 1 }
        var paged = try liveTab(orders.id, in: session.tabManager)
        paged.execution.lastExecutedAt = Date(timeIntervalSinceNow: 60)
        session.tabManager.updateTab(paged)
        session.driver.resumeFetchTableMetadata()
        await read.value

        #expect(session.coordinator.currentTableMetadata(for: paged)?.tableName == "orders")
        #expect(session.coordinator.tableMetadataCache[orders.id]?.lastExecutedAt == orders.execution.lastExecutedAt)
        #expect(!session.coordinator.hasCurrentTableMetadata(for: paged))
    }

    @Test("A slow read never replaces a newer one that landed first")
    func slowReadKeepsTheNewerEntry() async throws {
        let session = LiveSession()
        defer { session.tearDown() }
        let orders = addTableTab(to: session.tabManager, tableName: "orders")
        session.paneState.inspector.setOnScreen(true)
        session.driver.tableCommentToReturn = "old"
        session.driver.pausesNextFetchTableMetadata = true

        let slow = Task { await session.coordinator.loadTableMetadata(for: orders) }
        try await waitUntil { session.driver.fetchTableMetadataCalls.count == 1 }
        var reloaded = try liveTab(orders.id, in: session.tabManager)
        reloaded.execution.lastExecutedAt = Date(timeIntervalSinceNow: 60)
        session.tabManager.updateTab(reloaded)
        try cache(metadata("orders", comment: "new"), for: reloaded, in: session.coordinator)
        session.driver.resumeFetchTableMetadata()
        await slow.value

        #expect(session.coordinator.currentTableMetadata(for: reloaded)?.comment == "new")
        #expect(session.coordinator.hasCurrentTableMetadata(for: reloaded))
    }

    // MARK: - Changes that keep the tab on the same table

    /// The comment arm used to drop the entry before its refetch, then never pushed the result.
    @Test("Editing the comment keeps the old numbers on screen until the new ones land")
    func commentEditKeepsTheNumbersUntilTheRefetchLands() async throws {
        let session = LiveSession()
        defer { session.tearDown() }
        let orders = addTableTab(to: session.tabManager, tableName: "orders", database: session.connection.database)
        session.paneState.inspector.setOnScreen(true)
        try cache(metadata("orders", comment: "old"), for: orders, in: session.coordinator)
        session.driver.tableCommentToReturn = "new"
        let scope = DatabaseScope(connectionId: session.connection.id, database: session.connection.database, schema: nil)

        session.coordinator.applyObjectChange(
            DatabaseObjectChange(connectionId: session.connection.id, scope: scope, name: "orders", kind: .comment)
        )

        #expect(session.coordinator.currentTableMetadata(for: orders)?.comment == "old")
        #expect(!session.coordinator.hasCurrentTableMetadata(for: orders))
        try await waitUntil { session.coordinator.currentTableMetadata(for: orders)?.comment == "new" }
        #expect(session.coordinator.hasCurrentTableMetadata(for: orders))
    }

    /// Editing a comment does not run the tab again, so the stamp cannot tell a read made before
    /// the edit from one made after it. Stored as current, the old comment made the refetch skip.
    @Test("A read in flight across a comment edit shows, and never marks the numbers current")
    func readAcrossACommentEditStaysStale() async throws {
        let session = LiveSession()
        defer { session.tearDown() }
        let orders = addTableTab(to: session.tabManager, tableName: "orders")
        session.paneState.inspector.setOnScreen(true)
        session.driver.tableCommentToReturn = "old"
        session.driver.pausesNextFetchTableMetadata = true

        let early = Task { await session.coordinator.loadTableMetadata(for: orders) }
        try await waitUntil { session.driver.fetchTableMetadataCalls.count == 1 }
        session.driver.tableCommentToReturn = "new"
        session.coordinator.markTableMetadataStale(forTabs: [orders.id])
        session.driver.resumeFetchTableMetadata()
        await early.value

        #expect(session.coordinator.currentTableMetadata(for: orders)?.comment == "old")
        #expect(!session.coordinator.hasCurrentTableMetadata(for: orders))
        await session.coordinator.loadTableMetadata(for: orders)
        #expect(session.coordinator.currentTableMetadata(for: orders)?.comment == "new")
        #expect(session.coordinator.hasCurrentTableMetadata(for: orders))
    }

    @Test("A read started before a comment edit never replaces the one made after it")
    func readBeforeACommentEditKeepsTheLaterOne() async throws {
        let session = LiveSession()
        defer { session.tearDown() }
        let orders = addTableTab(to: session.tabManager, tableName: "orders")
        session.paneState.inspector.setOnScreen(true)
        session.driver.tableCommentToReturn = "old"
        session.driver.pausesNextFetchTableMetadata = true

        let early = Task { await session.coordinator.loadTableMetadata(for: orders) }
        try await waitUntil { session.driver.fetchTableMetadataCalls.count == 1 }
        session.coordinator.markTableMetadataStale(forTabs: [orders.id])
        try cache(metadata("orders", comment: "new"), for: orders, in: session.coordinator)
        session.driver.resumeFetchTableMetadata()
        await early.value

        #expect(session.coordinator.currentTableMetadata(for: orders)?.comment == "new")
        #expect(session.coordinator.hasCurrentTableMetadata(for: orders))
    }

    @Test("Numbers marked stale stay on screen when their refetch fails")
    func staleNumbersSurviveAFailedRefetch() async throws {
        let session = LiveSession()
        defer { session.tearDown() }
        let orders = addTableTab(to: session.tabManager, tableName: "orders")
        session.paneState.inspector.setOnScreen(true)
        try cache(metadata("orders", comment: "old"), for: orders, in: session.coordinator)
        session.driver.fetchTableMetadataError = DatabaseError.notConnected

        session.coordinator.markTableMetadataStale(forTabs: [orders.id])
        await session.coordinator.loadTableMetadata(for: orders)

        #expect(session.driver.fetchTableMetadataCalls == ["orders"])
        #expect(session.coordinator.currentTableMetadata(for: orders)?.comment == "old")
    }

    @Test("Renaming the table keeps its numbers under the new name, with no read")
    func renameKeepsTheNumbers() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let orders = addTableTab(to: tabManager, tableName: "orders", database: "shop")
        let shown = metadata("orders", rowCount: 10)
        try cache(shown, for: orders, in: coordinator)

        coordinator.retitleTabs(ids: [orders.id], to: "orders_old")
        let renamed = try liveTab(orders.id, in: tabManager)

        #expect(renamed.tableContext.tableName == "orders_old")
        #expect(coordinator.currentTableMetadata(for: renamed) == shown)
        #expect(coordinator.hasCurrentTableMetadata(for: renamed))
    }

    @Test("Renaming the database keeps the numbers of the tables in it")
    func containerRenameKeepsTheNumbers() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let orders = addTableTab(to: tabManager, tableName: "orders", database: "shop")
        let shown = metadata("orders", rowCount: 10)
        try cache(shown, for: orders, in: coordinator)

        coordinator.retargetTabs(database: "shop", schema: nil, toDatabase: "store", toSchema: nil)
        let moved = try liveTab(orders.id, in: tabManager)

        #expect(moved.tableContext.databaseName == "store")
        #expect(coordinator.currentTableMetadata(for: moved) == shown)
    }
}

/// PGlite cannot open a pooled connection, so the metadata read lands on the injected driver. The
/// coordinator holds its pane state weakly, so the session keeps it.
@MainActor
private struct LiveSession {
    let connection: DatabaseConnection
    let driver: MockDatabaseDriver
    let tabManager = QueryTabManager()
    let coordinator: MainContentCoordinator
    let paneState = TrailingPaneState()

    init() {
        connection = TestFixtures.makeConnection(type: .pglite)
        driver = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        coordinator.trailingPaneState = paneState
    }

    func tearDown() {
        coordinator.teardown()
        DatabaseManager.shared.removeSession(for: connection.id)
    }
}
