//
//  CoordinatorColumnVisibilityTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
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
        defer { FileColumnLayoutPersister.shared.clear(for: key) }

        coordinator.hideColumn("email")

        #expect(FileColumnLayoutPersister.shared.loadHiddenColumns(for: key) == ["email"])
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
    }

    @Test("Clearing layout after a schema reorder clears every geometry owner")
    func clearColumnLayoutForSelectedTableClearsEveryGeometryOwner() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")
        guard let tabIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected table tab")
            return
        }
        tabManager.mutate(at: tabIndex) { tab in
            tab.columnLayout.columnWidths = ["name": 180]
            tab.columnLayout.columnContentWidths = ["name": 160]
            tab.columnLayout.columnOrder = ["name", "id"]
            tab.columnLayout.hiddenColumns = ["email"]
        }

        let key = ColumnLayoutTableKey(
            connectionId: coordinator.connectionId,
            databaseName: tabManager.tabs[tabIndex].tableContext.databaseName,
            schemaName: tabManager.tabs[tabIndex].tableContext.schemaName,
            tableName: "users"
        )
        FileColumnLayoutPersister.shared.save(tabManager.tabs[tabIndex].columnLayout, for: key)
        FileColumnLayoutPersister.shared.saveHiddenColumns(["email"], for: key)
        defer { FileColumnLayoutPersister.shared.clear(for: key) }

        let rows = TableRows.from(
            queryRows: [[.text("Ada")]],
            columns: ["name"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let gridCoordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FileColumnLayoutPersister.shared
        )
        gridCoordinator.connectionId = coordinator.connectionId
        gridCoordinator.databaseName = ""
        gridCoordinator.tableName = "users"
        gridCoordinator.tabType = .table
        gridCoordinator.tableRowsProvider = { rows }
        gridCoordinator.rebuildColumnMetadataCache(from: rows)
        let tableView = NSTableView()
        gridCoordinator.tableView = tableView
        let column = NSTableColumn(identifier: try #require(gridCoordinator.columnIdentifier(for: 0)))
        column.width = 180
        tableView.addTableColumn(column)
        #expect(gridCoordinator.markColumnWidthUserSized(column))
        gridCoordinator.scheduleLayoutPersist()

        let gridDelegate = DataTabGridDelegate()
        gridDelegate.dataGridAttach(tableViewCoordinator: gridCoordinator)
        coordinator.dataTabDelegate = gridDelegate

        coordinator.clearColumnLayoutForSelectedTable()

        let layout = tabManager.tabs[tabIndex].columnLayout
        #expect(layout.columnWidths.isEmpty)
        #expect(layout.columnContentWidths == nil)
        #expect(layout.columnOrder == nil)
        #expect(layout.hiddenColumns == ["email"])
        #expect(FileColumnLayoutPersister.shared.load(for: key) == nil)
        #expect(FileColumnLayoutPersister.shared.loadHiddenColumns(for: key) == ["email"])
        #expect(gridCoordinator.userSizedColumnNames.isEmpty)
        #expect(gridCoordinator.shouldRecalculateAutomaticColumnWidths)
        #expect(gridCoordinator.pendingColumnLayoutPersistence == nil)
    }

    @Test("A delayed schema reorder clears only its captured table layout")
    func capturedSchemaReorderTargetDoesNotClearNewSelection() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let sourceTabId = addTableTab(to: tabManager, tableName: "users")
        let destinationTabId = addTableTab(to: tabManager, tableName: "orders")
        let sourceIndex = try #require(tabManager.tabs.firstIndex(where: { $0.id == sourceTabId }))
        let destinationIndex = try #require(tabManager.tabs.firstIndex(where: { $0.id == destinationTabId }))
        tabManager.mutate(at: sourceIndex) { tab in
            tab.columnLayout.columnWidths = ["name": 180]
            tab.columnLayout.columnContentWidths = ["name": 160]
            tab.columnLayout.columnOrder = ["name", "id"]
        }
        tabManager.mutate(at: destinationIndex) { tab in
            tab.columnLayout.columnWidths = ["name": 240]
            tab.columnLayout.columnContentWidths = ["name": 240]
            tab.columnLayout.columnOrder = ["id", "name"]
        }

        let sourceKey = ColumnLayoutTableKey(
            connectionId: coordinator.connectionId,
            databaseName: "",
            schemaName: nil,
            tableName: "users"
        )
        let destinationKey = ColumnLayoutTableKey(
            connectionId: coordinator.connectionId,
            databaseName: "",
            schemaName: nil,
            tableName: "orders"
        )
        FileColumnLayoutPersister.shared.save(tabManager.tabs[sourceIndex].columnLayout, for: sourceKey)
        FileColumnLayoutPersister.shared.save(tabManager.tabs[destinationIndex].columnLayout, for: destinationKey)
        defer {
            FileColumnLayoutPersister.shared.clear(for: sourceKey)
            FileColumnLayoutPersister.shared.clear(for: destinationKey)
        }

        tabManager.selectedTabId = sourceTabId
        let target = try #require(coordinator.selectedColumnLayoutClearTarget())
        tabManager.selectedTabId = destinationTabId

        let rows = TableRows.from(
            queryRows: [[.text("Ada")]],
            columns: ["name"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let gridCoordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FileColumnLayoutPersister.shared
        )
        gridCoordinator.connectionId = coordinator.connectionId
        gridCoordinator.databaseName = ""
        gridCoordinator.tableName = "orders"
        gridCoordinator.tabType = .table
        gridCoordinator.tableRowsProvider = { rows }
        gridCoordinator.rebuildColumnMetadataCache(from: rows)
        let tableView = NSTableView()
        gridCoordinator.tableView = tableView
        let column = NSTableColumn(identifier: try #require(gridCoordinator.columnIdentifier(for: 0)))
        column.width = 240
        tableView.addTableColumn(column)
        #expect(gridCoordinator.markColumnWidthUserSized(column))

        let gridDelegate = DataTabGridDelegate()
        gridDelegate.dataGridAttach(tableViewCoordinator: gridCoordinator)
        coordinator.dataTabDelegate = gridDelegate

        coordinator.clearColumnLayout(target)

        let sourceLayout = tabManager.tabs[sourceIndex].columnLayout
        let destinationLayout = tabManager.tabs[destinationIndex].columnLayout
        #expect(sourceLayout.columnWidths.isEmpty)
        #expect(sourceLayout.columnContentWidths == nil)
        #expect(sourceLayout.columnOrder == nil)
        #expect(destinationLayout.columnWidths == ["name": 240])
        #expect(destinationLayout.columnContentWidths == ["name": 240])
        #expect(destinationLayout.columnOrder == ["id", "name"])
        #expect(FileColumnLayoutPersister.shared.load(for: sourceKey) == nil)
        #expect(FileColumnLayoutPersister.shared.load(for: destinationKey)?.columnWidths == ["name": 240])
        #expect(gridCoordinator.userSizedColumnNames == ["name"])
        #expect(!gridCoordinator.shouldRecalculateAutomaticColumnWidths)
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
            for: coordinator.schemaColumnsKey("users", scope: coordinator.selectedTabScope)
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
            FileColumnLayoutPersister.shared.clear(for: key)
            coordinator.teardown()
        }

        FileColumnLayoutPersister.shared.saveHiddenColumns(["email"], for: key)
        coordinator.schemaColumns.store(
            (columns: ["id", "name", "email"], primaryKeys: ["id"]),
            for: coordinator.schemaColumnsKey("users", scope: coordinator.scope(for: createdTab))
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
