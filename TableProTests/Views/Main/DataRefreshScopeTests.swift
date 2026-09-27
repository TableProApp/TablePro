//
//  DataRefreshScopeTests.swift
//  TableProTests
//
//  A data-changed broadcast reaches every window of a connection. #2026 symptom 2 was
//  the whole window following a save: the refresh carried no scope, so every window
//  refetched against whatever database the save had pinned. The request now names the
//  scope the change landed in, and each receiver matches it against the scope it owns:
//  the sidebar against the browse cursor, an open tab against the tab's own scope.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Data refresh scoping", .serialized)
@MainActor
struct DataRefreshScopeTests {
    private static func makeCoordinator(
        connection: DatabaseConnection,
        browseDatabase: String,
        tabDatabase: String? = nil
    ) -> (MainContentCoordinator, QueryTabManager) {
        var session = ConnectionSession(connection: connection)
        session.browseDatabase = browseDatabase
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )

        if let tabDatabase {
            var tab = QueryTab(title: "orders", query: "SELECT 1", tabType: .table, tableName: "orders")
            tab.tableContext.databaseName = tabDatabase
            tabManager.tabs.append(tab)
            tabManager.selectedTabId = tab.id
        }

        return (coordinator, tabManager)
    }

    @Test("A scoped refresh is ignored by a window browsing another database")
    func scopedRefreshSkipsAWindowBrowsingElsewhere() throws {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, _) = Self.makeCoordinator(
            connection: connection,
            browseDatabase: "inventory",
            tabDatabase: "inventory"
        )

        let elsewhere = DatabaseScope(connectionId: connection.id, database: "orders", schema: nil)
        let request = DataRefreshRequest(connectionId: connection.id, scope: elsewhere)

        #expect(request.scope != coordinator.selectedTabScope)
        #expect(request.scope?.database != coordinator.browseDatabaseName)
    }

    @Test("An unscoped refresh still reaches every window")
    func unscopedRefreshReachesEveryone() {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, _) = Self.makeCoordinator(
            connection: connection,
            browseDatabase: "inventory",
            tabDatabase: "orders"
        )

        let request = DataRefreshRequest(connectionId: connection.id)

        #expect(request.scope == nil)
        #expect(coordinator.selectedTabScope != nil)
        #expect(coordinator.browseScope != nil)
    }

    @Test("A refresh scoped to a tab's own scope reaches that tab even when the sidebar moved away")
    func scopedRefreshReachesItsOwnTab() throws {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, _) = Self.makeCoordinator(
            connection: connection,
            browseDatabase: "inventory",
            tabDatabase: "orders"
        )

        let tabScope = try #require(coordinator.selectedTabScope)
        #expect(tabScope.database == "orders")

        let request = DataRefreshRequest(connectionId: connection.id, scope: tabScope)

        #expect(request.scope == tabScope)
        #expect(
            request.scope?.database != coordinator.browseDatabaseName,
            "Matching a structure tab on the browse database would drop its own post-save reload"
        )
    }

    @Test("The browse cursor and an open tab's scope are independent")
    func browseScopeAndTabScopeAreIndependent() throws {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, _) = Self.makeCoordinator(
            connection: connection,
            browseDatabase: "inventory",
            tabDatabase: "orders"
        )

        let browseScope = try #require(coordinator.browseScope)
        let tabScope = try #require(coordinator.selectedTabScope)

        #expect(browseScope.database == "inventory")
        #expect(tabScope.database == "orders")
        #expect(browseScope != tabScope)
    }

    @Test("A refresh for another connection never matches this window")
    func refreshForAnotherConnectionIsIgnored() throws {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, _) = Self.makeCoordinator(
            connection: connection,
            browseDatabase: "orders",
            tabDatabase: "orders"
        )

        let otherConnectionId = UUID()
        let otherScope = DatabaseScope(connectionId: otherConnectionId, database: "orders", schema: nil)
        let request = DataRefreshRequest(connectionId: otherConnectionId, scope: otherScope)

        #expect(request.connectionId != coordinator.connectionId)
        #expect(request.scope != coordinator.selectedTabScope)
    }

    private static func loadedTab(
        _ name: String,
        database: String,
        tabType: TabType = .table,
        in coordinator: MainContentCoordinator
    ) -> QueryTab {
        var tab = QueryTab(title: name, query: "SELECT 1", tabType: tabType, tableName: name)
        tab.tableContext.databaseName = database
        tab.execution.lastExecutedAt = Date()
        coordinator.tabSessionRegistry.setTableRows(
            TableRows.from(queryRows: [["1"]], columns: ["id"], columnTypes: [.text(rawType: nil)]),
            for: tab.id
        )
        return tab
    }

    @Test("A scoped refresh marks the table tabs in its scope, background ones too, and none elsewhere")
    func scopedRefreshMarksTheTableTabsInItsScope() {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection, browseDatabase: "inventory")
        let inScope = Self.loadedTab("orders", database: "orders", in: coordinator)
        let queryInScope = Self.loadedTab("orders", database: "orders", tabType: .query, in: coordinator)
        let elsewhere = Self.loadedTab("orders", database: "inventory", in: coordinator)
        tabManager.tabs = [inScope, queryInScope, elsewhere]
        tabManager.selectedTabId = elsewhere.id

        coordinator.applyDataRefresh(
            DataRefreshRequest(
                connectionId: connection.id,
                scope: DatabaseScope(connectionId: connection.id, database: "orders", schema: nil)
            )
        )

        let registry = coordinator.tabSessionRegistry
        #expect(registry.isStale(inScope.id))
        #expect(registry.tableRows(for: inScope.id).rows.count == 1)
        #expect(!registry.isStale(queryInScope.id))
        #expect(!registry.isStale(elsewhere.id))
    }

    @Test("An unscoped refresh marks every table tab on the connection")
    func unscopedRefreshMarksEveryTableTab() {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection, browseDatabase: "inventory")
        let first = Self.loadedTab("orders", database: "orders", in: coordinator)
        let second = Self.loadedTab("stock", database: "inventory", in: coordinator)
        tabManager.tabs = [first, second]

        coordinator.applyDataRefresh(DataRefreshRequest(connectionId: connection.id))

        #expect(coordinator.tabSessionRegistry.isStale(first.id))
        #expect(coordinator.tabSessionRegistry.isStale(second.id))
    }

    @Test("A refresh forgets every cached column list before the selected tab builds its reload")
    func refreshForgetsCachedColumnsBeforeTheReload() throws {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection, browseDatabase: "orders")
        var tab = Self.loadedTab("orders", database: "orders", in: coordinator)
        tab.columnLayout.hiddenColumns = ["note"]
        tabManager.tabs = [tab]
        tabManager.selectedTabId = tab.id
        let scope = try #require(coordinator.scope(for: tab))
        let shownKey = coordinator.schemaColumnsKey("orders", scope: scope)
        let unshownKey = coordinator.schemaColumnsKey("stock", scope: scope)
        let before = SchemaColumnStore.Entry(columns: ["id", "note", "dropped_col"], primaryKeys: ["id"], columnTypes: [:])
        coordinator.schemaColumns.store(before, for: shownKey)
        coordinator.schemaColumns.store(before, for: unshownKey)
        #expect(coordinator.selectColumns(for: tab) == ["id", "dropped_col"])

        coordinator.applyDataRefresh(DataRefreshRequest(connectionId: connection.id))

        let reloaded = try #require(tabManager.tabs.first { $0.id == tab.id })
        #expect(!reloaded.content.query.contains("dropped_col"))
        #expect(coordinator.schemaColumns.cached(shownKey) == nil)
        #expect(coordinator.schemaColumns.cached(unshownKey) == nil)
    }

    private static func loadedStructure(
        of tab: QueryTab,
        connection: DatabaseConnection,
        in coordinator: MainContentCoordinator
    ) -> StructureEditingSession {
        let session = StructureEditingSession(
            identity: tab.id.uuidString,
            connection: connection,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName,
            tableName: tab.tableContext.tableName ?? ""
        )
        session.hasLoaded = true
        coordinator.structureSessions[tab.id] = session
        return session
    }

    /// An import or a context switch can change any definition in its scope, and a structure left
    /// loaded behind the Data view, or behind another tab, was never told: it showed the columns
    /// from before the change when it was shown again.
    @Test("A refresh has the structure of every table tab it reaches fetched again, once any staged edits are gone")
    func refreshMarksTheStructureOfEveryTabItReaches() {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection, browseDatabase: "orders")
        let inScope = Self.loadedTab("orders", database: "orders", in: coordinator)
        let editing = Self.loadedTab("orders", database: "orders", in: coordinator)
        let elsewhere = Self.loadedTab("stock", database: "inventory", in: coordinator)
        tabManager.tabs = [inScope, editing, elsewhere]
        tabManager.selectedTabId = elsewhere.id
        let inScopeStructure = Self.loadedStructure(of: inScope, connection: connection, in: coordinator)
        let editingStructure = Self.loadedStructure(of: editing, connection: connection, in: coordinator)
        let elsewhereStructure = Self.loadedStructure(of: elsewhere, connection: connection, in: coordinator)
        editingStructure.changeManager.addNewColumn()

        coordinator.applyDataRefresh(
            DataRefreshRequest(
                connectionId: connection.id,
                scope: DatabaseScope(connectionId: connection.id, database: "orders", schema: nil)
            )
        )

        #expect(!inScopeStructure.hasLoaded)
        #expect(elsewhereStructure.hasLoaded)
        #expect(editingStructure.hasLoaded, "A structure holding staged edits keeps them")
        #expect(editingStructure.changeManager.hasChanges)

        editingStructure.changeManager.discardChanges()
        #expect(editingStructure.settleOwedRefetch())
        #expect(!editingStructure.hasLoaded)
    }

    @Test("A refresh for another connection marks nothing in this window")
    func refreshForAnotherConnectionMarksNothing() {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection, browseDatabase: "orders")
        let tab = Self.loadedTab("orders", database: "orders", in: coordinator)
        tabManager.tabs = [tab]

        coordinator.applyDataRefresh(DataRefreshRequest(connectionId: UUID()))

        #expect(!coordinator.tabSessionRegistry.isStale(tab.id))
    }
}
