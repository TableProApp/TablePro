//
//  CellFilterApplyTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class CellFilterLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// The cell menu's Filter item, from the menu the data tab's delegate builds to the query it runs.
@MainActor
struct CellFilterApplyTests {
    private let rows = TableRows.from(
        queryRows: [[.text("1"), .text("paid")], [.text("2"), .text("open")]],
        columns: ["id", "status"],
        columnTypes: [.integer(rawType: "INT"), .text(rawType: "VARCHAR(20)")]
    )

    private struct Harness {
        let coordinator: MainContentCoordinator
        let tabManager: QueryTabManager
        let grid: TableViewCoordinator
        let delegate: DataTabGridDelegate
        let tabId: UUID
    }

    private func makeHarness(tabType: TabType = .table, changeManager: DataChangeManager = DataChangeManager()) -> Harness {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: changeManager,
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(
            title: "orders",
            query: "SELECT * FROM orders",
            tabType: tabType,
            tableName: tabType == .table ? "orders" : nil
        )
        tab.tableContext.isEditable = true
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        coordinator.setActiveTableRows(rows, for: tab.id)

        let grid = TableViewCoordinator(
            changeManager: AnyChangeManager(changeManager),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: CellFilterLayoutPersister()
        )
        let tableRows = rows
        grid.tableRowsProvider = { tableRows }
        grid.rebuildColumnMetadataCache(from: tableRows)
        grid.updateCache()
        grid.visualIndex.rebuild(from: grid.changeManager)

        let delegate = DataTabGridDelegate()
        delegate.coordinator = coordinator
        delegate.dataGridAttach(tableViewCoordinator: grid)
        coordinator.dataTabDelegate = delegate
        return Harness(coordinator: coordinator, tabManager: tabManager, grid: grid, delegate: delegate, tabId: tab.id)
    }

    private func editedStatusOfFirstRow() -> DataChangeManager {
        let changes = DataChangeManager()
        changes.configureForTable(
            tableName: "orders",
            columns: ["id", "status"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: [],
            triggerReload: false
        )
        changes.recordCellChange(
            rowID: .existing(0),
            columnIndex: 1,
            columnName: "status",
            oldValue: .text("paid"),
            newValue: .text("void"),
            originalRow: [.text("1"), .text("paid")]
        )
        return changes
    }

    private func clearSavedFilters(_ harness: Harness) {
        FilterSettingsStorage.shared.clearLastFilters(
            for: "orders",
            connectionId: harness.coordinator.connectionId,
            databaseName: "",
            schemaName: nil
        )
    }

    @Test("A cell's Filter item lists the conditions for its value")
    func menuListsConditions() throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }

        let item = try #require(harness.delegate.dataGridFilterMenuItem(forRow: 1, dataColumn: 1))

        #expect(item.submenu?.items.map(\.title) == ["status = “open”", "status != “open”"])
    }

    @Test("Choosing a condition re-queries the table with it and shows the filter bar")
    func choosingAConditionRequeries() throws {
        let harness = makeHarness()
        defer {
            clearSavedFilters(harness)
            harness.coordinator.teardown()
        }
        let item = try #require(harness.delegate.dataGridFilterMenuItem(forRow: 0, dataColumn: 1))

        item.submenu?.performActionForItem(at: 0)

        let state = try #require(harness.tabManager.tabs.first { $0.id == harness.tabId }?.filterState)
        #expect(state.executedFilters.map(\.columnName) == ["status"])
        #expect(state.executedFilters.map(\.filterOperator) == [.equal])
        #expect(state.executedFilters.map(\.value) == ["paid"])
        #expect(state.appliedFilters.map(\.id) == state.executedFilters.map(\.id))
        #expect(state.isVisible)
    }

    @Test("A second condition narrows the first rather than replacing it")
    func secondConditionNarrows() throws {
        let harness = makeHarness()
        defer {
            clearSavedFilters(harness)
            harness.coordinator.teardown()
        }

        try #require(harness.delegate.dataGridFilterMenuItem(forRow: 0, dataColumn: 1))
            .submenu?.performActionForItem(at: 1)
        try #require(harness.delegate.dataGridFilterMenuItem(forRow: 1, dataColumn: 0))
            .submenu?.performActionForItem(at: 2)

        let state = try #require(harness.tabManager.tabs.first { $0.id == harness.tabId }?.filterState)
        #expect(state.executedFilters.map { "\($0.columnName) \($0.filterOperator.rawValue) \($0.value)" } == [
            "status != paid", "id > 2"
        ])
        #expect(state.filterLogicMode == .and)
    }

    /// The declined branch is reached by pretending an alert is already up, which is what
    /// `confirmDiscardChangesIfNeeded` answers false to once there are edits to lose.
    @Test("Nothing changes while the discard alert is unanswered")
    func declinedDiscardChangesNothing() throws {
        let harness = makeHarness(changeManager: editedStatusOfFirstRow())
        defer { harness.coordinator.teardown() }
        #expect(harness.coordinator.changeManager.hasChanges)
        let item = try #require(harness.delegate.dataGridFilterMenuItem(forRow: 1, dataColumn: 1))
        let before = try #require(harness.tabManager.tabs.first { $0.id == harness.tabId })
        harness.coordinator.isShowingConfirmAlert = true

        item.submenu?.performActionForItem(at: 0)

        let after = try #require(harness.tabManager.tabs.first { $0.id == harness.tabId })
        #expect(after.filterState == before.filterState)
        #expect(after.content.query == before.content.query)
    }

    @Test("A query result has no Filter item, because its rows have no table to filter")
    func queryTabHasNoItem() {
        let harness = makeHarness(tabType: .query)
        defer { harness.coordinator.teardown() }

        #expect(harness.delegate.dataGridFilterMenuItem(forRow: 0, dataColumn: 1) == nil)
    }

    @Test("An edited cell has no Filter item, because the server does not hold its value")
    func editedCellHasNoItem() {
        let harness = makeHarness(changeManager: editedStatusOfFirstRow())
        defer { harness.coordinator.teardown() }

        #expect(harness.delegate.dataGridFilterMenuItem(forRow: 0, dataColumn: 1) == nil)
        #expect(harness.delegate.dataGridFilterMenuItem(forRow: 0, dataColumn: 0) != nil)
        #expect(harness.delegate.dataGridFilterMenuItem(forRow: 1, dataColumn: 1) != nil)
    }

    @Test("The Filter item sits just before Highlight in the cell menu")
    func rowMenuPlacesFilterBeforeHighlight() throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }
        harness.grid.delegate = harness.delegate
        let tableView = KeyHandlingTableView()
        tableView.coordinator = harness.grid
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        harness.grid.tableView = tableView
        let rowView = DataGridRowView()
        rowView.coordinator = harness.grid
        rowView.rowIndex = 0

        let titles = try #require(rowView.contextMenu(target: .cell(dataColumn: 1))).items.map(\.title)

        let filterIndex = try #require(titles.firstIndex(of: "Filter"))
        #expect(titles.indices.contains(filterIndex + 1))
        #expect(titles[filterIndex + 1] == "Highlight")
    }
}
