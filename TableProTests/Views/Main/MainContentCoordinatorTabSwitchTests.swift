//
//  MainContentCoordinatorTabSwitchTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("MainContentCoordinator handleTabChange")
@MainActor
struct MainContentCoordinatorTabSwitchTests {
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            filterStateManager: FilterStateManager(),
            columnVisibilityManager: ColumnVisibilityManager(),
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
        let tableRows = TableRows.from(queryRows: rows, columns: columns, columnTypes: columnTypes)
        coordinator.setActiveTableRows(tableRows, for: tabId)
    }

    // MARK: - Save outgoing state

    @Test("Switching saves outgoing tab filter state into the tab")
    func savesOutgoingFilterState() {
        let (coordinator, tabManager) = makeCoordinator()
        let oldId = addQueryTab(to: tabManager, title: "Old")
        let newId = addQueryTab(to: tabManager, title: "New")
        seedRows(coordinator, for: oldId)
        seedRows(coordinator, for: newId)

        coordinator.filterStateManager.filters = [
            TestFixtures.makeTableFilter(column: "id", op: .equal, value: "42")
        ]
        coordinator.filterStateManager.appliedFilters = [
            TestFixtures.makeTableFilter(column: "id", op: .equal, value: "42")
        ]
        coordinator.filterStateManager.isVisible = true

        coordinator.handleTabChange(from: oldId, to: newId, tabs: tabManager.tabs)

        guard let oldIndex = tabManager.tabs.firstIndex(where: { $0.id == oldId }) else {
            Issue.record("Expected old tab to exist after switch")
            return
        }
        let saved = tabManager.tabs[oldIndex].filterState
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

    @Test("Switching saves outgoing column visibility state to the tab layout")
    func savesOutgoingColumnVisibility() {
        let (coordinator, tabManager) = makeCoordinator()
        let oldId = addTableTab(to: tabManager, tableName: "users")
        let newId = addTableTab(to: tabManager, tableName: "orders")
        seedRows(coordinator, for: oldId)
        seedRows(coordinator, for: newId)

        coordinator.columnVisibilityManager.hideColumn("name")

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
        savedFilter.appliedFilters = savedFilter.filters
        savedFilter.isVisible = true
        tabManager.tabs[newIndex].filterState = savedFilter

        coordinator.filterStateManager.filters = [
            TestFixtures.makeTableFilter(column: "old_col", op: .equal, value: "old")
        ]
        coordinator.filterStateManager.isVisible = false

        coordinator.handleTabChange(from: oldId, to: newId, tabs: tabManager.tabs)

        #expect(coordinator.filterStateManager.filters.count == 1)
        #expect(coordinator.filterStateManager.filters.first?.columnName == "name")
        #expect(coordinator.filterStateManager.filters.first?.value == "Bob")
        #expect(coordinator.filterStateManager.isVisible == true)
    }

    @Test("Switching restores hidden columns for the incoming tab")
    func restoresIncomingColumnVisibility() {
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

        coordinator.columnVisibilityManager.hideColumn("legacy_col")

        coordinator.handleTabChange(from: oldId, to: newId, tabs: tabManager.tabs)

        #expect(coordinator.columnVisibilityManager.hiddenColumns == ["email", "phone"])
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

        coordinator.handleTabChange(from: nil, to: newId, tabs: tabManager.tabs)

        #expect(coordinator.filterStateManager.filters.count == 1)
        #expect(coordinator.columnVisibilityManager.hiddenColumns == ["secret"])
    }

    @Test("Switching to nil clears the filter state and toolbar flags")
    func clearsStateOnSwitchToNil() {
        let (coordinator, tabManager) = makeCoordinator()
        let oldId = addTableTab(to: tabManager, tableName: "users")
        seedRows(coordinator, for: oldId)

        coordinator.filterStateManager.filters = [
            TestFixtures.makeTableFilter(column: "id", op: .equal, value: "1")
        ]
        coordinator.filterStateManager.isVisible = true
        coordinator.toolbarState.isTableTab = true
        coordinator.toolbarState.isResultsCollapsed = true

        coordinator.handleTabChange(from: oldId, to: nil, tabs: tabManager.tabs)

        #expect(coordinator.filterStateManager.filters.isEmpty)
        #expect(coordinator.filterStateManager.isVisible == false)
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
        coordinator.filterStateManager.filters = [
            TestFixtures.makeTableFilter(column: "id", op: .equal, value: "1")
        ]
        coordinator.filterStateManager.isVisible = true

        coordinator.handleTabChange(from: oldId, to: UUID(), tabs: tabManager.tabs)

        #expect(coordinator.filterStateManager.filters.isEmpty)
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

        coordinator.handleTabChange(from: UUID(), to: newId, tabs: tabManager.tabs)

        #expect(coordinator.filterStateManager.filters.count == 1)
        #expect(coordinator.filterStateManager.filters.first?.value == "777")
    }

    // MARK: - FilterState round-trip seam

    @Test("FilterStateManager save then restore round-trips all visible state")
    func filterStateManagerRoundTrip() {
        let manager = FilterStateManager()
        manager.filters = [
            TestFixtures.makeTableFilter(column: "id", op: .equal, value: "1"),
            TestFixtures.makeTableFilter(column: "name", op: .contains, value: "a")
        ]
        manager.appliedFilters = [manager.filters[0]]
        manager.isVisible = true
        manager.filterLogicMode = .or

        let snapshot = manager.saveToTabState()

        manager.clearAll()
        #expect(manager.filters.isEmpty)
        #expect(manager.isVisible == false)

        manager.restoreFromTabState(snapshot)
        #expect(manager.filters.count == 2)
        #expect(manager.appliedFilters.count == 1)
        #expect(manager.isVisible == true)
        #expect(manager.filterLogicMode == .or)
    }

    @Test("DataChangeManager restoreState rehydrates table context and changes")
    func dataChangeManagerRestoresFromSnapshot() {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
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

        fresh.restoreState(from: snapshot, tableName: "users", databaseType: .postgresql)

        #expect(fresh.hasChanges == true)
        #expect(fresh.tableName == "users")
        #expect(fresh.primaryKeyColumns == ["id"])
        #expect(fresh.databaseType == .postgresql)
        #expect(fresh.columns == ["id", "name"])
    }

    @Test("ColumnVisibilityManager round-trips hidden columns through layout state")
    func columnVisibilityManagerRoundTrip() {
        let manager = ColumnVisibilityManager()
        manager.hideColumn("email")
        manager.hideColumn("phone")

        let saved = manager.saveToColumnLayout()
        #expect(saved == ["email", "phone"])

        manager.showAll()
        #expect(manager.hiddenColumns.isEmpty)

        manager.restoreFromColumnLayout(saved)
        #expect(manager.hiddenColumns == ["email", "phone"])
    }
}
