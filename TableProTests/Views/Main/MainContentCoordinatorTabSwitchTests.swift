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
        state.appliedFilters = state.filters
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
        savedFilter.appliedFilters = savedFilter.filters
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

        coordinator.applySelectedFilters()
        #expect(coordinator.selectedTabFilterState.appliedFilters.count == 2)
        #expect(coordinator.selectedTabFilterState.filterLogicMode == .or)

        coordinator.clearFilterState()
        #expect(coordinator.selectedTabFilterState.filters.isEmpty)
        #expect(coordinator.selectedTabFilterState.appliedFilters.isEmpty)
        #expect(coordinator.selectedTabFilterState.isVisible == false)
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
}
