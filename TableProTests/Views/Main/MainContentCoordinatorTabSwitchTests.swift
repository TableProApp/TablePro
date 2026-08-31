//
//  MainContentCoordinatorTabSwitchTests.swift
//  TableProTests
//

import AppKit
import CodeEditSourceEditor
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class RetargetColumnLayoutPersister: ColumnLayoutPersisting {
    var stored: [String: ColumnLayoutState] = [:]

    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? {
        stored[key.tableName]
    }

    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {
        stored[key.tableName] = layout
    }

    func clear(for key: ColumnLayoutTableKey) {
        stored.removeValue(forKey: key.tableName)
    }
}

@Suite("MainContentCoordinator handleTabChange")
@MainActor
struct MainContentCoordinatorTabSwitchTests {
    private func makeCoordinator(
        connection: DatabaseConnection = TestFixtures.makeConnection()
    ) -> (MainContentCoordinator, QueryTabManager) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        return (coordinator, tabManager)
    }

    private func addQueryTab(
        to tabManager: QueryTabManager,
        title: String = "Query 1",
        query: String = "SELECT 1"
    ) -> UUID {
        var tab = QueryTab(title: title, query: query, tabType: .query)
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab.id
    }

    private func addTableTab(
        to tabManager: QueryTabManager,
        tableName: String,
        databaseName: String = ""
    ) -> UUID {
        var tab = QueryTab(
            title: tableName,
            query: "SELECT * FROM \(tableName)",
            tabType: .table,
            tableName: tableName
        )
        tab.tableContext.databaseName = databaseName
        tab.tableContext.isEditable = true
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab.id
    }

    private func seedRows(
        _ coordinator: MainContentCoordinator,
        for tabId: UUID,
        columns: [String] = ["id", "name"],
        rowCount: Int = 3
    ) {
        let rows = (0..<rowCount).map { i in columns.map { "\($0)_\(i)" as String? } }
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: columns.count)
        let tableRows = TableRows.from(queryRows: rows.map { row in row.map(PluginCellValue.fromOptional) }, columns: columns, columnTypes: columnTypes)
        coordinator.setActiveTableRows(tableRows, for: tabId)
    }

    private func attachPendingQueryGrid(
        to coordinator: MainContentCoordinator,
        tabId: UUID,
        width: CGFloat
    ) throws -> (TableViewCoordinator, DataTabGridDelegate) {
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
            layoutPersister: RetargetColumnLayoutPersister()
        )
        gridCoordinator.tabType = .query
        gridCoordinator.tableRowsProvider = { rows }
        gridCoordinator.rebuildColumnMetadataCache(from: rows)

        let tableView = NSTableView()
        gridCoordinator.tableView = tableView
        let column = NSTableColumn(identifier: try #require(gridCoordinator.columnIdentifier(for: 0)))
        column.width = width
        tableView.addTableColumn(column)
        gridCoordinator.updateColumnPresentations(from: rows)
        #expect(gridCoordinator.markColumnWidthUserSized(column))
        gridCoordinator.onColumnLayoutDidChange = { [weak coordinator] layout in
            coordinator?.applyColumnGeometry(from: layout, toTabId: tabId)
        }
        gridCoordinator.scheduleLayoutPersist()

        let gridDelegate = DataTabGridDelegate()
        gridDelegate.dataGridAttach(tableViewCoordinator: gridCoordinator)
        coordinator.dataTabDelegate = gridDelegate
        return (gridCoordinator, gridDelegate)
    }

    @Test("Retargeting a table flushes its pending width before the tab geometry resets")
    func retargetFlushesOutgoingColumnLayoutBeforeReset() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "orders", databaseName: "app")
        let rows = TableRows.from(
            queryRows: [[.text("Ada")]],
            columns: ["name"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let persister = RetargetColumnLayoutPersister()
        let gridCoordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: persister
        )
        gridCoordinator.connectionId = coordinator.connectionId
        gridCoordinator.databaseName = "app"
        gridCoordinator.tableName = "orders"
        gridCoordinator.tabType = .table
        gridCoordinator.tableRowsProvider = { rows }
        gridCoordinator.rebuildColumnMetadataCache(from: rows)

        let tableView = NSTableView()
        gridCoordinator.tableView = tableView
        let column = NSTableColumn(identifier: try #require(gridCoordinator.columnIdentifier(for: 0)))
        column.width = 180
        tableView.addTableColumn(column)
        gridCoordinator.updateColumnPresentations(from: rows)
        #expect(gridCoordinator.markColumnWidthUserSized(column))
        gridCoordinator.onColumnLayoutDidChange = { [weak coordinator] layout in
            coordinator?.applyColumnGeometry(from: layout, toTabId: tabId)
        }
        gridCoordinator.scheduleLayoutPersist()

        let gridDelegate = DataTabGridDelegate()
        gridDelegate.dataGridAttach(tableViewCoordinator: gridCoordinator)
        coordinator.dataTabDelegate = gridDelegate

        try tabManager.replaceTabContent(
            tableName: "customers",
            databaseType: .mysql,
            databaseName: "app"
        )

        let retargetedTab = try #require(tabManager.tabs.first(where: { $0.id == tabId }))
        #expect(persister.stored["orders"]?.columnWidths == ["name": 180])
        #expect(gridCoordinator.pendingColumnLayoutPersistence == nil)
        #expect(retargetedTab.tableContext.tableName == "customers")
        #expect(retargetedTab.columnLayout == ColumnLayoutState())
    }

    @Test("Closing a window flushes a pending query width before saving tabs")
    func windowCloseFlushesPendingQueryColumnLayout() async throws {
        let wasTerminating = MainContentCoordinator.isAppTerminating
        MainContentCoordinator.isAppTerminating = false
        defer { MainContentCoordinator.isAppTerminating = wasTerminating }

        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager)
        let (gridCoordinator, gridDelegate) = try attachPendingQueryGrid(
            to: coordinator,
            tabId: tabId,
            width: 180
        )
        _ = gridDelegate
        coordinator.registerEagerly()
        coordinator.persistence.markObservedTabs()
        TabDiskActor.clearSync(connectionId: coordinator.connectionId)

        coordinator.handleWindowWillClose()
        let restored = await coordinator.persistence.restoreFromDisk()

        #expect(gridCoordinator.pendingColumnLayoutPersistence == nil)
        #expect(restored.tabs.first?.columnLayout.columnWidths == ["name": 180])
        #expect(restored.tabs.first?.columnLayout.columnContentWidths == ["name": 180])

        coordinator.persistence.clearForUserClosedAllTabs()
    }

    @Test("Disconnect persistence flushes pending query widths from every coordinator")
    func disconnectPersistenceFlushesEveryPendingQueryColumnLayout() async throws {
        let connection = TestFixtures.makeConnection()
        let (firstCoordinator, firstTabManager) = makeCoordinator(connection: connection)
        let (secondCoordinator, secondTabManager) = makeCoordinator(connection: connection)
        let firstTabId = addQueryTab(to: firstTabManager, title: "First")
        let secondTabId = addQueryTab(to: secondTabManager, title: "Second")
        let (firstGrid, firstDelegate) = try attachPendingQueryGrid(
            to: firstCoordinator,
            tabId: firstTabId,
            width: 180
        )
        let (secondGrid, secondDelegate) = try attachPendingQueryGrid(
            to: secondCoordinator,
            tabId: secondTabId,
            width: 220
        )
        _ = (firstDelegate, secondDelegate)

        firstCoordinator.registerEagerly()
        secondCoordinator.registerEagerly()
        firstCoordinator.persistence.markObservedTabs()
        secondCoordinator.persistence.markObservedTabs()
        TabDiskActor.clearSync(connectionId: connection.id)
        defer {
            TabDiskActor.clearSync(connectionId: connection.id)
            firstCoordinator.teardown()
            secondCoordinator.teardown()
        }

        SessionTabStatePersister().persistTabState(for: connection.id)
        let restored = await firstCoordinator.persistence.restoreFromDisk()
        let firstTab = try #require(restored.tabs.first(where: { $0.id == firstTabId }))
        let secondTab = try #require(restored.tabs.first(where: { $0.id == secondTabId }))

        #expect(firstGrid.pendingColumnLayoutPersistence == nil)
        #expect(secondGrid.pendingColumnLayoutPersistence == nil)
        #expect(firstTab.columnLayout.columnWidths == ["name": 180])
        #expect(secondTab.columnLayout.columnWidths == ["name": 220])
    }

    @Test("Connection-close persistence runs before coordinator teardown")
    func connectionClosePersistencePrecedesCoordinatorTeardown() async throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager)
        let (gridCoordinator, gridDelegate) = try attachPendingQueryGrid(
            to: coordinator,
            tabId: tabId,
            width: 180
        )
        _ = gridDelegate
        coordinator.registerEagerly()
        coordinator.persistence.markObservedTabs()
        TabDiskActor.clearSync(connectionId: coordinator.connectionId)
        defer { TabDiskActor.clearSync(connectionId: coordinator.connectionId) }

        SessionTabStatePersister().persistTabState(for: coordinator.connectionId)
        coordinator.teardown()
        let restored = await coordinator.persistence.restoreFromDisk()

        #expect(gridCoordinator.pendingColumnLayoutPersistence == nil)
        #expect(tabManager.tabs.isEmpty)
        #expect(restored.tabs.first?.columnLayout.columnWidths == ["name": 180])
        #expect(restored.tabs.first?.columnLayout.columnContentWidths == ["name": 180])
    }

    @Test("Closing a query tab flushes its pending width into recently closed state")
    func closingQueryTabFlushesPendingColumnLayout() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addQueryTab(to: tabManager)
        let (gridCoordinator, gridDelegate) = try attachPendingQueryGrid(
            to: coordinator,
            tabId: tabId,
            width: 180
        )
        _ = gridDelegate
        defer {
            RecentlyClosedTabStore.shared.removeEntries(for: coordinator.connectionId)
            coordinator.teardown()
        }

        coordinator.closeTabsByUser(ids: [tabId])

        let closedTab = RecentlyClosedTabStore.shared.entries.first {
            $0.connectionId == coordinator.connectionId && $0.tab.id == tabId
        }
        #expect(gridCoordinator.pendingColumnLayoutPersistence == nil)
        #expect(tabManager.tabs.isEmpty)
        #expect(closedTab?.tab.columnWidths == ["name": 180])
        #expect(closedTab?.tab.columnContentWidths == ["name": 180])
    }

    // MARK: - Save outgoing state

    @Test("Filter state set on the active tab survives a tab switch")
    func outgoingTabFilterStatePersists() {
        let (coordinator, tabManager) = makeCoordinator()
        let oldId = addQueryTab(to: tabManager, title: "Old")
        let newId = addQueryTab(to: tabManager, title: "New")
        seedRows(coordinator, for: oldId)
        seedRows(coordinator, for: newId)

        guard let oldIndex = tabManager.tabs.firstIndex(where: { $0.id == oldId }) else {
            Issue.record("Expected old tab to exist before switch")
            return
        }
        var state = TabFilterState()
        state.filters = [TestFixtures.makeTableFilter(column: "id", op: .equal, value: "42")]
        state.commit = .all
        state.isVisible = true
        tabManager.tabs[oldIndex].filterState = state

        coordinator.handleTabChange(from: oldId, to: newId, tabs: tabManager.tabs)

        guard let oldIndexAfter = tabManager.tabs.firstIndex(where: { $0.id == oldId }) else {
            Issue.record("Expected old tab to exist after switch")
            return
        }
        let saved = tabManager.tabs[oldIndexAfter].filterState
        #expect(saved.filters.count == 1)
        #expect(saved.appliedFilters.count == 1)
        #expect(saved.filters.first?.value == "42")
        #expect(saved.isVisible == true)
    }

    @Test("Switching saves outgoing pending changes into the tab")
    func savesOutgoingPendingChanges() {
        let (coordinator, tabManager) = makeCoordinator()
        let oldId = addQueryTab(to: tabManager, title: "Old")
        let newId = addQueryTab(to: tabManager, title: "New")
        seedRows(coordinator, for: oldId)
        seedRows(coordinator, for: newId)

        coordinator.changeManager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: [],
            triggerReload: false
        )
        coordinator.changeManager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob",
            originalRow: ["1", "Alice"]
        )
        #expect(coordinator.changeManager.hasChanges == true)

        coordinator.handleTabChange(from: oldId, to: newId, tabs: tabManager.tabs)

        guard let oldIndex = tabManager.tabs.firstIndex(where: { $0.id == oldId }) else {
            Issue.record("Expected old tab to exist after switch")
            return
        }
        #expect(tabManager.tabs[oldIndex].pendingChanges.hasChanges == true)
    }

    @Test("Hiding a column persists into the active tab's column layout")
    func hidingColumnPersistsToActiveTab() {
        let (coordinator, tabManager) = makeCoordinator()
        let oldId = addTableTab(to: tabManager, tableName: "users")
        let newId = addTableTab(to: tabManager, tableName: "orders")
        seedRows(coordinator, for: oldId)
        seedRows(coordinator, for: newId)

        tabManager.selectedTabId = oldId
        coordinator.hideColumn("name")

        coordinator.handleTabChange(from: oldId, to: newId, tabs: tabManager.tabs)

        guard let oldIndex = tabManager.tabs.firstIndex(where: { $0.id == oldId }) else {
            Issue.record("Expected old tab to exist after switch")
            return
        }
        #expect(tabManager.tabs[oldIndex].columnLayout.hiddenColumns.contains("name"))
    }

    // MARK: - Restore incoming state

    @Test("Switching restores filter state for the incoming tab")
    func restoresIncomingFilterState() {
        let (coordinator, tabManager) = makeCoordinator()
        let oldId = addQueryTab(to: tabManager, title: "Old")
        let newId = addQueryTab(to: tabManager, title: "New")
        seedRows(coordinator, for: oldId)
        seedRows(coordinator, for: newId)

        guard let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId }) else {
            Issue.record("Expected new tab to exist before switch")
            return
        }
        var savedFilter = TabFilterState()
        savedFilter.filters = [TestFixtures.makeTableFilter(column: "name", op: .equal, value: "Bob")]
        savedFilter.commit = .all
        savedFilter.isVisible = true
        tabManager.tabs[newIndex].filterState = savedFilter

        tabManager.selectedTabId = newId
        coordinator.handleTabChange(from: oldId, to: newId, tabs: tabManager.tabs)

        let exposed = coordinator.selectedTabFilterState
        #expect(exposed.filters.count == 1)
        #expect(exposed.filters.first?.columnName == "name")
        #expect(exposed.filters.first?.value == "Bob")
        #expect(exposed.isVisible == true)
    }

    @Test("Switching to a tab exposes that tab's hidden columns through the coordinator")
    func incomingTabExposesHiddenColumns() {
        let (coordinator, tabManager) = makeCoordinator()
        let oldId = addTableTab(to: tabManager, tableName: "users")
        let newId = addTableTab(to: tabManager, tableName: "orders")
        seedRows(coordinator, for: oldId)
        seedRows(coordinator, for: newId)

        guard let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId }) else {
            Issue.record("Expected new tab to exist before switch")
            return
        }
        tabManager.tabs[newIndex].columnLayout.hiddenColumns = ["email", "phone"]

        tabManager.selectedTabId = newId
        coordinator.handleTabChange(from: oldId, to: newId, tabs: tabManager.tabs)

        #expect(coordinator.selectedTabHiddenColumns == ["email", "phone"])
    }

    @Test("Switching restores selected row indices for the incoming tab")
    func restoresIncomingSelectedRows() {
        let (coordinator, tabManager) = makeCoordinator()
        let oldId = addQueryTab(to: tabManager, title: "Old")
        let newId = addQueryTab(to: tabManager, title: "New")
        seedRows(coordinator, for: oldId)
        seedRows(coordinator, for: newId)

        guard let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId }) else {
            Issue.record("Expected new tab to exist before switch")
            return
        }
        tabManager.tabs[newIndex].selectedRowIndices = [3, 5, 7]

        coordinator.selectionState.indices = [99]

        coordinator.handleTabChange(from: oldId, to: newId, tabs: tabManager.tabs)

        #expect(coordinator.selectionState.indices == [3, 5, 7])
    }

    @Test("Switching to a table tab marks toolbar as table tab")
    func toolbarReflectsTableTabType() {
        let (coordinator, tabManager) = makeCoordinator()
        let queryId = addQueryTab(to: tabManager, title: "Query")
        let tableId = addTableTab(to: tabManager, tableName: "users")
        seedRows(coordinator, for: queryId)
        seedRows(coordinator, for: tableId)

        coordinator.toolbarState.isTableTab = false

        coordinator.handleTabChange(from: queryId, to: tableId, tabs: tabManager.tabs)

        #expect(coordinator.toolbarState.isTableTab == true)
    }

    @Test("Switching to a query tab clears toolbar table tab flag")
    func toolbarClearsTableTabOnQuerySwitch() {
        let (coordinator, tabManager) = makeCoordinator()
        let tableId = addTableTab(to: tabManager, tableName: "users")
        let queryId = addQueryTab(to: tabManager, title: "Query")
        seedRows(coordinator, for: tableId)
        seedRows(coordinator, for: queryId)

        coordinator.toolbarState.isTableTab = true

        coordinator.handleTabChange(from: tableId, to: queryId, tabs: tabManager.tabs)

        #expect(coordinator.toolbarState.isTableTab == false)
    }

    @Test("Switching restores results-collapsed state from the incoming tab")
    func restoresIncomingResultsCollapsedFlag() {
        let (coordinator, tabManager) = makeCoordinator()
        let oldId = addQueryTab(to: tabManager, title: "Old")
        let newId = addQueryTab(to: tabManager, title: "New")
        seedRows(coordinator, for: oldId)
        seedRows(coordinator, for: newId)

        guard let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId }) else {
            Issue.record("Expected new tab to exist before switch")
            return
        }
        tabManager.tabs[newIndex].display.isResultsCollapsed = true

        coordinator.toolbarState.isResultsCollapsed = false

        coordinator.handleTabChange(from: oldId, to: newId, tabs: tabManager.tabs)

        #expect(coordinator.toolbarState.isResultsCollapsed == true)
    }

    // MARK: - Pending changes restore

    @Test("Switching restores pending changes when the incoming tab has them")
    func restoresIncomingPendingChanges() {
        let (coordinator, tabManager) = makeCoordinator()
        let oldId = addTableTab(to: tabManager, tableName: "users")
        let newId = addTableTab(to: tabManager, tableName: "orders")
        seedRows(coordinator, for: oldId)
        seedRows(coordinator, for: newId, columns: ["id", "total"])

        coordinator.changeManager.configureForTable(
            tableName: "orders",
            columns: ["id", "total"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: [],
            triggerReload: false
        )
        coordinator.changeManager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "total",
            oldValue: "10",
            newValue: "99",
            originalRow: ["1", "10"]
        )
        let snapshot = coordinator.changeManager.saveState()

        guard let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId }) else {
            Issue.record("Expected new tab to exist before switch")
            return
        }
        tabManager.tabs[newIndex].pendingChanges = snapshot

        coordinator.changeManager.clearChanges()
        #expect(coordinator.changeManager.hasChanges == false)

        coordinator.handleTabChange(from: oldId, to: newId, tabs: tabManager.tabs)

        #expect(coordinator.changeManager.hasChanges == true)
        #expect(coordinator.changeManager.tableName == "orders")
    }

    @Test("Switching configures the change manager when the incoming tab has no pending state")
    func configuresChangeManagerWhenNoPendingState() {
        let (coordinator, tabManager) = makeCoordinator()
        let oldId = addQueryTab(to: tabManager, title: "Old")
        let newId = addTableTab(to: tabManager, tableName: "products")
        seedRows(coordinator, for: oldId)
        seedRows(coordinator, for: newId, columns: ["id", "name", "price"])

        guard let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId }) else {
            Issue.record("Expected new tab to exist before switch")
            return
        }
        tabManager.tabs[newIndex].tableContext.primaryKeyColumns = ["id"]
        tabManager.tabs[newIndex].pendingChanges = TabChangeSnapshot()

        coordinator.handleTabChange(from: oldId, to: newId, tabs: tabManager.tabs)

        #expect(coordinator.changeManager.tableName == "products")
        #expect(coordinator.changeManager.primaryKeyColumns == ["id"])
        #expect(coordinator.changeManager.hasChanges == false)
    }

    // MARK: - Edge cases

    @Test("Switching from nil to a valid tab restores that tab's state")
    func restoresStateOnInitialSwitch() {
        let (coordinator, tabManager) = makeCoordinator()
        let newId = addQueryTab(to: tabManager, title: "Initial")
        seedRows(coordinator, for: newId)

        guard let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId }) else {
            Issue.record("Expected new tab to exist before switch")
            return
        }
        var savedFilter = TabFilterState()
        savedFilter.filters = [TestFixtures.makeTableFilter(column: "id", op: .equal, value: "1")]
        savedFilter.isVisible = true
        tabManager.tabs[newIndex].filterState = savedFilter
        tabManager.tabs[newIndex].columnLayout.hiddenColumns = ["secret"]

        tabManager.selectedTabId = newId
        coordinator.handleTabChange(from: nil, to: newId, tabs: tabManager.tabs)

        #expect(coordinator.selectedTabFilterState.filters.count == 1)
        #expect(coordinator.selectedTabHiddenColumns == ["secret"])
    }

    @Test("Switching to nil resets toolbar flags")
    func clearsStateOnSwitchToNil() {
        let (coordinator, tabManager) = makeCoordinator()
        let oldId = addTableTab(to: tabManager, tableName: "users")
        seedRows(coordinator, for: oldId)

        coordinator.toolbarState.isTableTab = true
        coordinator.toolbarState.isResultsCollapsed = true

        coordinator.handleTabChange(from: oldId, to: nil, tabs: tabManager.tabs)

        #expect(coordinator.toolbarState.isTableTab == false)
        #expect(coordinator.toolbarState.isResultsCollapsed == false)
    }

    @Test("isHandlingTabSwitch is reset to false after the call returns")
    func clearsHandlingFlagAfterCall() {
        let (coordinator, tabManager) = makeCoordinator()
        let oldId = addQueryTab(to: tabManager, title: "Old")
        let newId = addQueryTab(to: tabManager, title: "New")
        seedRows(coordinator, for: oldId)
        seedRows(coordinator, for: newId)

        coordinator.handleTabChange(from: oldId, to: newId, tabs: tabManager.tabs)

        #expect(coordinator.isHandlingTabSwitch == false)
    }

    @Test("Switching to an unknown new tab id falls through to the clear branch")
    func unknownNewIdClears() {
        let (coordinator, tabManager) = makeCoordinator()
        let oldId = addTableTab(to: tabManager, tableName: "users")
        seedRows(coordinator, for: oldId)

        coordinator.toolbarState.isTableTab = true

        coordinator.handleTabChange(from: oldId, to: UUID(), tabs: tabManager.tabs)

        #expect(coordinator.toolbarState.isTableTab == false)
    }

    @Test("Switching from an unknown outgoing id still restores the new tab")
    func unknownOutgoingIdStillRestoresIncoming() {
        let (coordinator, tabManager) = makeCoordinator()
        let newId = addQueryTab(to: tabManager, title: "New")
        seedRows(coordinator, for: newId)

        guard let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId }) else {
            Issue.record("Expected new tab to exist before switch")
            return
        }
        var savedFilter = TabFilterState()
        savedFilter.filters = [TestFixtures.makeTableFilter(column: "id", op: .equal, value: "777")]
        tabManager.tabs[newIndex].filterState = savedFilter

        tabManager.selectedTabId = newId
        coordinator.handleTabChange(from: UUID(), to: newId, tabs: tabManager.tabs)

        #expect(coordinator.selectedTabFilterState.filters.count == 1)
        #expect(coordinator.selectedTabFilterState.filters.first?.value == "777")
    }

    // MARK: - FilterState round-trip seam

    @Test("Coordinator filter helpers round-trip through the active tab's filter state")
    func filterStateRoundTripThroughActiveTab() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")
        seedRows(coordinator, for: tabId)

        let f1 = TestFixtures.makeTableFilter(column: "id", op: .equal, value: "1")
        let f2 = TestFixtures.makeTableFilter(column: "name", op: .contains, value: "a")
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        tabManager.tabs[index].filterState.filters = [f1, f2]
        tabManager.tabs[index].filterState.filterLogicMode = .or
        tabManager.tabs[index].filterState.isVisible = true

        coordinator.applyAllFilters()
        #expect(coordinator.selectedTabFilterState.appliedFilters.count == 2)
        #expect(coordinator.selectedTabFilterState.filterLogicMode == .or)

        coordinator.clearFilterState()
        #expect(coordinator.selectedTabFilterState.filters.isEmpty)
        #expect(coordinator.selectedTabFilterState.appliedFilters.isEmpty)
        #expect(coordinator.selectedTabFilterState.isVisible == true)
    }

    @Test("Apply All runs only enabled filters but keeps disabled ones in the panel")
    func applyAllExcludesDisabledFilters() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")
        seedRows(coordinator, for: tabId)

        let active = TestFixtures.makeTableFilter(column: "id", op: .equal, value: "1")
        let inactive = TestFixtures.makeTableFilter(column: "name", op: .contains, value: "a", isEnabled: false)
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        tabManager.tabs[index].filterState.filters = [active, inactive]

        coordinator.applyAllFilters()

        #expect(coordinator.selectedTabFilterState.filters.count == 2)
        #expect(coordinator.selectedTabFilterState.appliedFilters == [active])
    }

    @Test("Removing the soloed filter clears the applied set")
    func removingSoloedFilterClearsCommit() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")
        seedRows(coordinator, for: tabId)

        let first = TestFixtures.makeTableFilter(column: "id", op: .equal, value: "1")
        let second = TestFixtures.makeTableFilter(column: "name", op: .contains, value: "a")
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        tabManager.tabs[index].filterState.filters = [first, second]

        coordinator.applySoloFilter(second)
        #expect(coordinator.selectedTabFilterState.appliedFilters.map(\.id) == [second.id])

        coordinator.removeFilter(second)
        #expect(coordinator.selectedTabFilterState.appliedFilters.isEmpty)
    }

    @Test("Soloing an invalid filter does nothing")
    func soloingInvalidFilterIsNoOp() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")
        seedRows(coordinator, for: tabId)

        let invalid = TestFixtures.makeTableFilter(column: "", value: "")
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        tabManager.tabs[index].filterState.filters = [invalid]

        coordinator.applySoloFilter(invalid)
        #expect(coordinator.selectedTabFilterState.appliedFilters.isEmpty)
    }

    @Test("Apply on a single row queries by only that row without changing checkbox state")
    func applySoloFilterRunsOnlyThatRowAndKeepsState() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")
        seedRows(coordinator, for: tabId)

        let first = TestFixtures.makeTableFilter(column: "id", op: .equal, value: "1")
        let second = TestFixtures.makeTableFilter(column: "name", op: .contains, value: "a", isEnabled: false)
        let third = TestFixtures.makeTableFilter(column: "email", op: .contains, value: "b")
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        tabManager.tabs[index].filterState.filters = [first, second, third]

        coordinator.applySoloFilter(second)

        let state = coordinator.selectedTabFilterState
        #expect(state.filters.map(\.isEnabled) == [true, false, true])
        #expect(state.appliedFilters.map(\.id) == [second.id])
        #expect(state.appliedFilters.first?.isEnabled == true)
    }

    @Test("Applying filters persists them immediately so a reopened table restores them")
    func applyFiltersPersistForReopen() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")
        seedRows(coordinator, for: tabId)
        defer {
            FilterSettingsStorage.shared.clearLastFilters(
                for: "users",
                connectionId: coordinator.connectionId,
                databaseName: "",
                schemaName: nil
            )
        }

        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        tabManager.tabs[index].filterState.filters = [
            TestFixtures.makeTableFilter(column: "id", op: .equal, value: "1")
        ]

        coordinator.applyAllFilters()

        let persisted = FilterSettingsStorage.shared.loadLastFilters(
            for: "users",
            connectionId: coordinator.connectionId,
            databaseName: "",
            schemaName: nil
        )
        #expect(persisted.count == 1)
        #expect(persisted.first?.columnName == "id")
    }

    @Test("Disabled filters persist so they are available again after reopening a table")
    func disabledFiltersPersistForReopen() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")
        seedRows(coordinator, for: tabId)
        defer {
            FilterSettingsStorage.shared.clearLastFilters(
                for: "users",
                connectionId: coordinator.connectionId,
                databaseName: "",
                schemaName: nil
            )
        }

        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        tabManager.tabs[index].filterState.filters = [
            TestFixtures.makeTableFilter(column: "id", op: .equal, value: "1"),
            TestFixtures.makeTableFilter(column: "name", op: .contains, value: "a", isEnabled: false)
        ]

        coordinator.applyAllFilters()

        let persisted = FilterSettingsStorage.shared.loadLastFilters(
            for: "users",
            connectionId: coordinator.connectionId,
            databaseName: "",
            schemaName: nil
        )
        #expect(persisted.count == 2)
        #expect(persisted.contains { $0.columnName == "name" && !$0.isEnabled })
    }

    @Test("DataChangeManager restoreState rehydrates table context and changes")
    func dataChangeManagerRestoresFromSnapshot() {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: [],
            triggerReload: false
        )
        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob",
            originalRow: ["1", "Alice"]
        )
        let snapshot = manager.saveState()

        let fresh = DataChangeManager()
        #expect(fresh.hasChanges == false)

        fresh.restoreState(from: snapshot, tableName: "users", databaseType: .postgresql, generatedColumns: [])

        #expect(fresh.hasChanges == true)
        #expect(fresh.tableName == "users")
        #expect(fresh.primaryKeyColumns == ["id"])
        #expect(fresh.databaseType == .postgresql)
        #expect(fresh.columns == ["id", "name"])
    }

    @Test("Coordinator helpers round-trip hidden columns through the active tab's layout")
    func columnVisibilityHelpersRoundTrip() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")
        seedRows(coordinator, for: tabId)

        coordinator.hideColumn("email")
        coordinator.hideColumn("phone")
        #expect(coordinator.selectedTabHiddenColumns == ["email", "phone"])

        coordinator.showAllColumns()
        #expect(coordinator.selectedTabHiddenColumns.isEmpty)

        coordinator.hideAllColumns(["email", "phone"])
        #expect(coordinator.selectedTabHiddenColumns == ["email", "phone"])

        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[index].columnLayout.hiddenColumns == ["email", "phone"])
    }

    // MARK: - The caret of the tab being left

    /// One editor serves every query tab, so the live caret describes the outgoing tab only until
    /// the switch completes. Persistence writes it for the selected tab alone, and the tab's own
    /// restored value was already cleared when its editor consumed it, so a caret not captured on
    /// the way out is simply gone.
    @Test("Switching away from a query tab keeps its caret on the tab")
    func switchingAwayCapturesTheCaret() {
        let (coordinator, tabManager) = makeCoordinator()
        let first = addQueryTab(to: tabManager, title: "A", query: String(repeating: "SELECT 1;\n", count: 200))
        let second = addQueryTab(to: tabManager, title: "B")

        coordinator.cursorPositions = [CursorPosition(range: NSRange(location: 120, length: 8))]
        tabManager.selectedTabId = second
        coordinator.handleTabChange(from: first, to: second, tabs: tabManager.tabs)

        guard let index = tabManager.tabs.firstIndex(where: { $0.id == first }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[index].restoredCursorOffset == 120)
        #expect(tabManager.tabs[index].restoredCursorLength == 8)
    }

    @Test("A captured caret survives into the persisted record")
    func capturedCaretIsPersisted() {
        let (coordinator, tabManager) = makeCoordinator()
        let first = addQueryTab(to: tabManager, title: "A", query: String(repeating: "SELECT 1;\n", count: 200))
        let second = addQueryTab(to: tabManager, title: "B")

        coordinator.cursorPositions = [CursorPosition(range: NSRange(location: 90, length: 0))]
        tabManager.selectedTabId = second
        coordinator.handleTabChange(from: first, to: second, tabs: tabManager.tabs)

        guard let index = tabManager.tabs.firstIndex(where: { $0.id == first }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[index].toPersistedTab().cursorOffset == 90)
    }

    @Test("Leaving a table tab records no caret")
    func tableTabRecordsNoCaret() {
        let (coordinator, tabManager) = makeCoordinator()
        let table = addTableTab(to: tabManager, tableName: "users")
        let query = addQueryTab(to: tabManager, title: "B")

        coordinator.cursorPositions = [CursorPosition(range: NSRange(location: 42, length: 0))]
        tabManager.selectedTabId = query
        coordinator.handleTabChange(from: table, to: query, tabs: tabManager.tabs)

        guard let index = tabManager.tabs.firstIndex(where: { $0.id == table }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[index].restoredCursorOffset == nil)
    }
}
