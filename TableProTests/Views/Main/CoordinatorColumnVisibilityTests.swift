//
//  CoordinatorColumnVisibilityTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MainContentCoordinator column visibility helpers")
@MainActor
struct CoordinatorColumnVisibilityTests {
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

    private func addTableTab(
        to tabManager: QueryTabManager,
        tableName: String
    ) -> UUID {
        var tab = QueryTab(
            title: tableName,
            query: "SELECT * FROM \(tableName)",
            tabType: .table,
            tableName: tableName
        )
        tab.tableContext.isEditable = true
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab.id
    }

    @Test("hideColumn inserts into the active tab's hidden set")
    func hideColumn() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")

        coordinator.hideColumn("name")

        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[index].columnLayout.hiddenColumns == ["name"])
    }

    @Test("Hiding a column persists immediately so a reopened table restores it")
    func hideColumnPersistsForReopen() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, tableName: "users")
        guard let tab = tabManager.selectedTab else {
            Issue.record("Expected selected tab")
            return
        }
        let key = ColumnLayoutTableKey(
            connectionId: coordinator.connectionId,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName,
            tableName: "users"
        )
        defer { UserDefaults.standard.removeObject(forKey: ColumnVisibilityPersistence.key(for: key)) }

        coordinator.hideColumn("email")

        #expect(ColumnVisibilityPersistence.loadHiddenColumns(for: key) == ["email"])
    }

    @Test("Applying column geometry after hiding columns keeps the hidden set and syncs the session")
    func applyColumnGeometryPreservesHiddenColumns() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")
        coordinator.hideColumn("email")

        var geometry = ColumnLayoutState()
        geometry.columnWidths = ["id": 80, "name": 220]
        geometry.columnOrder = ["id", "name"]
        coordinator.applyColumnGeometry(from: geometry, toTabId: tabId)

        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        let layout = tabManager.tabs[index].columnLayout
        #expect(layout.hiddenColumns == ["email"])
        #expect(layout.columnWidths == ["id": 80, "name": 220])
        #expect(layout.columnOrder == ["id", "name"])

        let session = coordinator.tabSessionRegistry.session(for: tabId)
        #expect(session?.columnLayout.hiddenColumns == ["email"])
        #expect(session?.columnLayout.columnWidths == ["id": 80, "name": 220])
    }

    @Test("showColumn removes from the active tab's hidden set")
    func showColumn() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, tableName: "users")
        coordinator.hideColumn("name")
        coordinator.hideColumn("email")

        coordinator.showColumn("name")

        #expect(coordinator.selectedTabHiddenColumns == ["email"])
    }

    @Test("toggleColumnVisibility flips state")
    func toggleColumnVisibility() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, tableName: "users")

        coordinator.toggleColumnVisibility("name")
        #expect(coordinator.selectedTabHiddenColumns.contains("name"))

        coordinator.toggleColumnVisibility("name")
        #expect(!coordinator.selectedTabHiddenColumns.contains("name"))
    }

    @Test("showAllColumns clears hidden set on the active tab")
    func showAllColumns() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, tableName: "users")
        coordinator.hideAllColumns(["a", "b", "c"])

        coordinator.showAllColumns()
        #expect(coordinator.selectedTabHiddenColumns.isEmpty)
    }

    @Test("hideAllColumns replaces the hidden set with the supplied columns")
    func hideAllColumns() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, tableName: "users")
        coordinator.hideColumn("legacy")

        coordinator.hideAllColumns(["one", "two"])
        #expect(coordinator.selectedTabHiddenColumns == ["one", "two"])
    }

    @Test("pruneHiddenColumns drops hidden names that no longer exist in the schema")
    func pruneHiddenColumns() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, tableName: "users")
        coordinator.hideAllColumns(["a", "b", "c", "d"])
        coordinator.schemaColumns.store(
            (columns: ["b", "d", "e"], primaryKeys: []),
            for: coordinator.schemaColumnsKey("users", schema: nil)
        )

        coordinator.pruneHiddenColumns(currentColumns: ["b", "d", "e"])
        #expect(coordinator.selectedTabHiddenColumns == ["b", "d"])
    }

    @Test("hideColumn is idempotent")
    func hideColumnIdempotent() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, tableName: "users")

        coordinator.hideColumn("name")
        coordinator.hideColumn("name")
        #expect(coordinator.selectedTabHiddenColumns == ["name"])
    }

    @Test("hideColumn mirrors into the corresponding TabSession")
    func hideColumnMirrorsIntoSession() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")

        coordinator.hideColumn("name")

        let session = coordinator.tabSessionRegistry.session(for: tabId)
        #expect(session?.columnLayout.hiddenColumns == ["name"])
    }

    @Test("Payload-created table tabs rebuild their query after restoring hidden columns")
    func payloadCreatedTableTabsRebuildQueryAfterRestoringHiddenColumns() async {
        let connection = TestFixtures.makeConnection(database: "db")
        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .table,
            tableName: "users",
            databaseName: "db"
        )
        let state = SessionStateFactory.create(connection: connection, payload: payload)
        let coordinator = state.coordinator
        guard let createdTab = state.tabManager.selectedTab else {
            Issue.record("Expected payload-created table tab")
            return
        }
        let key = ColumnLayoutTableKey(
            connectionId: connection.id,
            databaseName: createdTab.tableContext.databaseName,
            schemaName: createdTab.tableContext.schemaName,
            tableName: "users"
        )

        defer {
            UserDefaults.standard.removeObject(forKey: ColumnVisibilityPersistence.key(for: key))
            coordinator.teardown()
        }

        ColumnVisibilityPersistence.saveHiddenColumns(["email"], for: key)
        coordinator.schemaColumns.store(
            (columns: ["id", "name", "email"], primaryKeys: ["id"]),
            for: coordinator.schemaColumnsKey("users", schema: nil)
        )

        coordinator.restoreLastHiddenColumnsForTable()
        await coordinator.rebuildSelectedTableQueryForHiddenColumnsIfNeeded()

        guard let tab = state.tabManager.selectedTab else {
            Issue.record("Expected payload-created table tab")
            return
        }

        #expect(tab.columnLayout.hiddenColumns == ["email"])
        #expect(tab.content.query.contains("SELECT *") == false)
        #expect(tab.content.query.contains("id"))
        #expect(tab.content.query.contains("name"))
        #expect(tab.content.query.contains("email") == false)
    }
}
