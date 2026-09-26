//
//  CatalogChangeWindowTests.swift
//  TableProTests
//
//  What each window does with its connection's catalog changes: close the tabs on an object or a
//  container that went, and follow a rename, matching by the object rather than a bare name.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Catalog changes in a window", .serialized)
@MainActor
struct CatalogChangeWindowTests {
    private static func makeCoordinator(
        connection: DatabaseConnection
    ) -> (MainContentCoordinator, QueryTabManager) {
        var session = ConnectionSession(connection: connection)
        session.browseDatabase = "shop"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        return (coordinator, tabManager)
    }

    private static func tableTab(_ name: String, database: String, schema: String?) -> QueryTab {
        var tab = QueryTab(title: name, query: "SELECT 1", tabType: .table, tableName: name)
        tab.tableContext.databaseName = database
        tab.tableContext.schemaName = schema
        return tab
    }

    private static func change(
        _ connection: DatabaseConnection,
        name: String,
        database: String,
        schema: String?,
        kind: DatabaseObjectChange.Kind
    ) -> DatabaseObjectChange {
        DatabaseObjectChange(
            connectionId: connection.id,
            scope: DatabaseScope(connectionId: connection.id, database: database, schema: schema),
            name: name,
            kind: kind
        )
    }

    @Test("a dropped table closes its tabs and no tab on a same-named table in another schema")
    func droppedTableClosesOnlyItsOwnTabs() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let dropped = Self.tableTab("users", database: "shop", schema: "analytics")
        let survivor = Self.tableTab("users", database: "shop", schema: "public")
        let query = QueryTab(title: "Query", query: "DROP TABLE analytics.users", tabType: .query)
        tabManager.tabs = [dropped, survivor, query]
        tabManager.selectedTabId = dropped.id

        coordinator.applyObjectChange(
            Self.change(connection, name: "users", database: "shop", schema: "analytics", kind: .dropped),
            hasPendingTableOps: false,
            onDiscard: {}
        )

        #expect(tabManager.tabs.map(\.id) == [survivor.id, query.id])
        #expect(tabManager.selectedTabId == survivor.id)
    }

    @Test("a renamed table retitles its tabs and leaves others alone")
    func renamedTableRetitlesItsTabs() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let renamed = Self.tableTab("orders", database: "shop", schema: nil)
        let other = Self.tableTab("orders", database: "warehouse", schema: nil)
        tabManager.tabs = [renamed, other]

        coordinator.applyObjectChange(
            Self.change(connection, name: "orders", database: "shop", schema: nil, kind: .renamed(to: "orders_2026")),
            hasPendingTableOps: false,
            onDiscard: {}
        )

        #expect(tabManager.tabs[0].tableContext.tableName == "orders_2026")
        #expect(tabManager.tabs[0].title == "orders_2026")
        #expect(tabManager.tabs[1].tableContext.tableName == "orders")
    }

    @Test("a dropped database closes the table tabs inside it")
    func droppedDatabaseClosesItsTabs() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let inside = Self.tableTab("events", database: "staging", schema: nil)
        let outside = Self.tableTab("orders", database: "shop", schema: nil)
        tabManager.tabs = [inside, outside]

        coordinator.applyContainerChange(
            DatabaseContainerChange(connectionId: connection.id, container: .database("staging"), kind: .dropped)
        )

        #expect(tabManager.tabs.map(\.id) == [outside.id])
    }

    @Test("a renamed schema moves its tabs onto the new name")
    func renamedSchemaRetargetsItsTabs() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let moved = Self.tableTab("invoices", database: "shop", schema: "billing")
        let untouched = Self.tableTab("orders", database: "shop", schema: "public")
        tabManager.tabs = [moved, untouched]

        coordinator.applyContainerChange(
            DatabaseContainerChange(
                connectionId: connection.id,
                container: .schema(database: "shop", schema: "billing"),
                kind: .renamed(to: "finance")
            )
        )

        #expect(tabManager.tabs[0].tableContext.schemaName == "finance")
        #expect(tabManager.tabs[1].tableContext.schemaName == "public")
    }

    private static func loadRows(_ tab: QueryTab, into coordinator: MainContentCoordinator, _ tabManager: QueryTabManager) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let tableRows = TestFixtures.makeTableRows(rowCount: 3)
        coordinator.setActiveTableRows(tableRows, for: tab.id)
        let resultSet = ResultSet(label: tab.title, tableRows: tableRows)
        tabManager.mutate(at: index) { tab in
            tab.display.resultSets = [resultSet]
            tab.display.activeResultSetId = resultSet.id
            tab.execution.lastExecutedAt = Date()
        }
    }

    private static func structureSession(
        for tab: QueryTab,
        connection: DatabaseConnection,
        into coordinator: MainContentCoordinator
    ) -> StructureEditingSession {
        let session = StructureEditingSession(
            identity: tab.id.uuidString,
            connection: connection,
            databaseName: tab.tableContext.databaseName,
            schemaName: nil,
            tableName: tab.tableContext.tableName ?? ""
        )
        session.hasLoaded = true
        coordinator.structureSessions[tab.id] = session
        return session
    }

    /// A Structure save reloaded the selected tab of each window on the database whatever table it
    /// showed, skipped the saving tab's Data view because Structure was in front, and left every
    /// background tab on the table with the rows from before the save.
    @Test("a structure change reloads the table's rows behind Structure and in the background, and no other table's")
    func structureChangeReachesEveryTabOnTheTable() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        defer { coordinator.cancelAllQueryTasks() }
        var saving = Self.tableTab("orders", database: "shop", schema: nil)
        saving.display.resultsViewMode = .structure
        let background = Self.tableTab("orders", database: "shop", schema: nil)
        let unrelated = Self.tableTab("users", database: "shop", schema: nil)
        tabManager.tabs = [background, unrelated, saving]
        for tab in tabManager.tabs {
            Self.loadRows(tab, into: coordinator, tabManager)
        }
        tabManager.selectedTabId = saving.id

        coordinator.applyObjectChange(
            Self.change(connection, name: "orders", database: "shop", schema: nil, kind: .structure),
            hasPendingTableOps: false,
            onDiscard: {}
        )

        #expect(coordinator.queryTasks.hasTask(for: saving.id))
        #expect(coordinator.tabSessionRegistry.isEvicted(background.id))
        #expect(!coordinator.tabSessionRegistry.isEvicted(unrelated.id))
        #expect(!coordinator.queryTasks.hasTask(for: unrelated.id))
        #expect(coordinator.tabSessionRegistry.tableRows(for: unrelated.id).rows.count == 3)
    }

    @Test("a structure change leaves the rows of a tab holding data edits, and never prompts")
    func structureChangeKeepsEditedRows() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        defer { coordinator.cancelAllQueryTasks() }
        var saving = Self.tableTab("orders", database: "shop", schema: nil)
        saving.display.resultsViewMode = .structure
        saving.pendingChanges.deletedRowIDs = [.existing(0)]
        tabManager.tabs = [saving]
        Self.loadRows(saving, into: coordinator, tabManager)
        tabManager.selectedTabId = saving.id

        coordinator.applyObjectChange(
            Self.change(connection, name: "orders", database: "shop", schema: nil, kind: .structure),
            hasPendingTableOps: false,
            onDiscard: {}
        )

        #expect(!coordinator.queryTasks.hasTask(for: saving.id))
        #expect(coordinator.tabSessionRegistry.tableRows(for: saving.id).rows.count == 3)
    }

    /// The saving tab still holds its edits while its save runs, and keeps them when the save
    /// stops partway, so a refetch, which adopts a new baseline, would throw away what the retry
    /// needs.
    @Test("a structure change marks unedited structure stale and leaves staged edits and their baseline alone")
    func structureChangeSparesStagedEdits() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        defer { coordinator.cancelAllQueryTasks() }
        let clean = Self.tableTab("orders", database: "shop", schema: nil)
        let edited = Self.tableTab("orders", database: "shop", schema: nil)
        let other = Self.tableTab("users", database: "shop", schema: nil)
        tabManager.tabs = [clean, edited, other]
        let cleanSession = Self.structureSession(for: clean, connection: connection, into: coordinator)
        let editedSession = Self.structureSession(for: edited, connection: connection, into: coordinator)
        editedSession.changeManager.addNewColumn()
        let otherSession = Self.structureSession(for: other, connection: connection, into: coordinator)
        tabManager.selectedTabId = other.id

        coordinator.applyObjectChange(
            Self.change(connection, name: "orders", database: "shop", schema: nil, kind: .structure),
            hasPendingTableOps: false,
            onDiscard: {}
        )

        #expect(cleanSession.hasLoaded == false)
        #expect(editedSession.hasLoaded)
        #expect(editedSession.changeManager.hasChanges)
        #expect(otherSession.hasLoaded)
    }

    /// A reload of a tab with hidden columns builds its select list from these before it fetches
    /// anything, so a column the save dropped would still be named in it.
    @Test("a structure change forgets the table's cached columns and keeps every other table's")
    func structureChangeForgetsCachedColumns() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let orders = Self.tableTab("orders", database: "shop", schema: nil)
        tabManager.tabs = [orders]
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)
        let entry = SchemaColumnStore.Entry(columns: ["id", "old"], primaryKeys: ["id"], columnTypes: [:])
        let ordersKey = coordinator.schemaColumnsKey("orders", scope: scope)
        let usersKey = coordinator.schemaColumnsKey("users", scope: scope)
        coordinator.schemaColumns.store(entry, for: ordersKey)
        coordinator.schemaColumns.store(entry, for: usersKey)

        coordinator.applyObjectChange(
            Self.change(connection, name: "orders", database: "shop", schema: nil, kind: .structure),
            hasPendingTableOps: false,
            onDiscard: {}
        )

        #expect(coordinator.schemaColumns.cached(ordersKey) == nil)
        #expect(coordinator.schemaColumns.cached(usersKey) == entry)
    }

    @Test("a change for another connection is ignored")
    func otherConnectionIsIgnored() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let tab = Self.tableTab("orders", database: "shop", schema: nil)
        tabManager.tabs = [tab]

        coordinator.applyContainerChange(
            DatabaseContainerChange(connectionId: UUID(), container: .database("shop"), kind: .dropped)
        )

        #expect(tabManager.tabs.map(\.id) == [tab.id])
    }
}
