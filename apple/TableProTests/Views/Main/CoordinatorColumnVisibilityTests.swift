//
//  CoordinatorColumnVisibilityTests.swift
//  TableProTests
//

import AppKit
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

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

    private func stageEdit(on coordinator: MainContentCoordinator) {
        coordinator.changeManager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: [],
            triggerReload: false
        )
        coordinator.changeManager.recordCellChange(
            rowID: .existing(0),
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob",
            originalRow: ["1", "Alice"]
        )
    }

    // Hiding a column re-queries, so an unsaved edit would go with the rows. The declined branch pretends an alert
    // is already up, which `confirmDiscardChangesIfNeeded` answers false to, keeping the test off the real modal.
    @Test("hiding a column changes nothing while the discard is unanswered")
    func hidingWaitsForTheDiscardAnswer() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")
        stageEdit(on: coordinator)
        coordinator.isShowingConfirmAlert = true

        coordinator.hideColumn("name")

        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        #expect(tab.columnLayout.hiddenColumns.isEmpty)
    }

    @Test("showing every column changes nothing while the discard is unanswered")
    func showAllWaitsForTheDiscardAnswer() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")
        coordinator.hideColumn("name")
        stageEdit(on: coordinator)
        coordinator.isShowingConfirmAlert = true

        coordinator.showAllColumns()

        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        #expect(tab.columnLayout.hiddenColumns == ["name"])
    }

    @Test("resetting the columns changes nothing while the discard is unanswered")
    func resetWaitsForTheDiscardAnswer() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")
        coordinator.hideColumn("name")
        stageEdit(on: coordinator)
        coordinator.isShowingConfirmAlert = true

        coordinator.resetColumns()

        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        #expect(tab.columnLayout.hiddenColumns == ["name"])
    }

    // With nothing staged the gate answers at once.
    @Test("hiding a column with no unsaved edits applies straight away")
    func hidingWithNoEditsAppliesImmediately() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")

        coordinator.hideColumn("name")

        let tab = try #require(tabManager.tabs.first { $0.id == tabId })
        #expect(tab.columnLayout.hiddenColumns == ["name"])
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

    private func usersKey(_ coordinator: MainContentCoordinator, _ tab: QueryTab, table: String = "users") -> ColumnLayoutTableKey {
        ColumnLayoutTableKey(
            connectionId: coordinator.connectionId,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName,
            tableName: table
        )
    }

    @Test("A grid geometry change after hiding columns keeps the hidden set and reaches the tab")
    func gridGeometryPreservesHiddenColumns() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")
        let key = usersKey(coordinator, try #require(tabManager.selectedTab))
        defer {
            coordinator.releaseGridModel(forTab: tabId, persistingLayout: false)
            FileColumnLayoutPersister.shared.clear(for: key)
        }
        coordinator.hideColumn("email")

        coordinator.gridModel(forTab: tabId).columnGeometryDidChange(widths: ["id": 80, "name": 220], order: ["id", "name"])

        let layout = try #require(tabManager.tabs.first { $0.id == tabId }).columnLayout
        #expect(layout.hiddenColumns == ["email"])
        #expect(layout.columnWidths == ["id": 80, "name": 220])
        #expect(layout.columnOrder == ["id", "name"])
    }

    @Test("Clearing layout after a schema reorder clears the tab, the store and a pending write")
    func clearColumnLayoutForSelectedTableClearsEveryGeometryOwner() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")
        let tabIndex = try #require(tabManager.tabs.firstIndex(where: { $0.id == tabId }))
        tabManager.mutate(at: tabIndex) { tab in
            tab.columnLayout.columnWidths = ["name": 180]
            tab.columnLayout.columnContentWidths = ["name": 160]
            tab.columnLayout.columnOrder = ["name", "id"]
            tab.columnLayout.hiddenColumns = ["email"]
        }
        let key = usersKey(coordinator, tabManager.tabs[tabIndex])
        FileColumnLayoutPersister.shared.save(tabManager.tabs[tabIndex].columnLayout, for: key)
        FileColumnLayoutPersister.shared.saveHiddenColumns(["email"], for: key)
        defer {
            coordinator.releaseGridModel(forTab: tabId, persistingLayout: false)
            FileColumnLayoutPersister.shared.clear(for: key)
        }
        coordinator.setActiveTableRows(
            TableRows.from(queryRows: [[.text("Ada")]], columns: ["name"], columnTypes: [.text(rawType: "TEXT")]),
            for: tabId
        )
        let model = coordinator.gridModel(forTab: tabId)
        model.columnGeometryDidChange(widths: ["name": 200], order: nil)

        coordinator.clearColumnLayoutForSelectedTable()
        coordinator.flushColumnLayoutPersistence()

        let layout = tabManager.tabs[tabIndex].columnLayout
        #expect(layout.columnWidths.isEmpty)
        #expect(layout.columnContentWidths == nil)
        #expect(layout.columnOrder == nil)
        #expect(layout.hiddenColumns == ["email"])
        #expect(FileColumnLayoutPersister.shared.load(for: key) == nil)
        #expect(FileColumnLayoutPersister.shared.loadHiddenColumns(for: key) == ["email"])
        #expect(model.store.columnLayout.columnWidths.isEmpty)
        #expect(model.store.columnLayout.columnContentWidths == nil)
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

        let sourceKey = usersKey(coordinator, tabManager.tabs[sourceIndex])
        let destinationKey = usersKey(coordinator, tabManager.tabs[destinationIndex], table: "orders")
        FileColumnLayoutPersister.shared.save(tabManager.tabs[sourceIndex].columnLayout, for: sourceKey)
        FileColumnLayoutPersister.shared.save(tabManager.tabs[destinationIndex].columnLayout, for: destinationKey)
        defer {
            coordinator.releaseGridModel(forTab: destinationTabId, persistingLayout: false)
            FileColumnLayoutPersister.shared.clear(for: sourceKey)
            FileColumnLayoutPersister.shared.clear(for: destinationKey)
        }

        tabManager.selectedTabId = sourceTabId
        let target = try #require(coordinator.selectedColumnLayoutClearTarget())
        tabManager.selectedTabId = destinationTabId
        coordinator.setActiveTableRows(
            TableRows.from(queryRows: [[.text("Ada")]], columns: ["name"], columnTypes: [.text(rawType: "TEXT")]),
            for: destinationTabId
        )
        let destinationModel = coordinator.gridModel(forTab: destinationTabId)
        #expect(destinationModel.store.columnLayout.columnWidths == ["name": 240])

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
        #expect(destinationModel.store.columnLayout.columnWidths == ["name": 240])
    }

    // The freeze lives in the table's stored layout, which the tab's own copy never records.
    @Test("clearing a table's layout unfreezes its grid model")
    func clearingTheLayoutUnfreezesTheModel() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "orders")
        let target = try #require(coordinator.selectedColumnLayoutClearTarget())
        var stored = ColumnLayoutState()
        stored.columnOrder = ["id", "name"]
        stored.frozenColumnCount = 2
        FileColumnLayoutPersister.shared.save(stored, for: target.tableKey)
        defer {
            coordinator.releaseGridModel(forTab: tabId, persistingLayout: false)
            FileColumnLayoutPersister.shared.clear(for: target.tableKey)
        }
        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [[.text("1"), .text("Ada")]],
                columns: ["id", "name"],
                columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
            ),
            for: tabId
        )
        let model = coordinator.gridModel(forTab: tabId)
        #expect(model.columns.frozenCount == 2)
        #expect(tabManager.selectedTab?.columnLayout.frozenColumnCount == 0)

        coordinator.clearColumnLayout(target)

        #expect(model.columns.frozenCount == 0)
        #expect(FileColumnLayoutPersister.shared.load(for: target.tableKey) == nil)
    }

    // A query tab's requery reloads nothing, so only the model can bring the hidden columns back to its grid.
    @Test("Reset Columns on a query tab shows the hidden columns in its grid and keeps Show All Columns working")
    func resetOnAQueryTabShowsHiddenColumnsInTheGrid() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tab = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        defer { coordinator.releaseGridModel(forTab: tab.id, persistingLayout: false) }
        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [[.text("1"), .text("Ada"), .text("ada@example.com")]],
                columns: ["id", "name", "email"],
                columnTypes: Array(repeating: .text(rawType: "TEXT"), count: 3)
            ),
            for: tab.id
        )
        let model = coordinator.gridModel(forTab: tab.id)
        coordinator.hideColumn("email")
        #expect(model.columns.orderedNames == ["id", "name"])

        coordinator.resetColumns()

        #expect(model.columns.orderedNames == ["id", "name", "email"])
        let layout = try #require(tabManager.selectedTab).columnLayout
        #expect(layout == ColumnLayoutState())

        coordinator.hideColumn("name")
        coordinator.showAllColumns()

        #expect(model.columns.orderedNames == ["id", "name", "email"])
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
            SchemaColumnStore.Entry(columns: ["b", "d", "e"], primaryKeys: [], columnTypes: [:]),
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
            SchemaColumnStore.Entry(columns: ["id", "name", "email"], primaryKeys: ["id"], columnTypes: [:]),
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
