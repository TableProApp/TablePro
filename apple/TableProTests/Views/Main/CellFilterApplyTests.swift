//
//  CellFilterApplyTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// The cell menu's Filter item, from the items the data tab's adapter contributes to the query it runs.
@MainActor
struct CellFilterApplyTests {
    private let rows = TableRows.from(
        queryRows: [[.text("1"), .text("paid")], [.text("2"), .text("open")]],
        columns: ["id", "status"],
        columnTypes: [.integer(rawType: "INT"), .text(rawType: "VARCHAR(20)")]
    )

    @MainActor
    private struct Harness {
        let coordinator: MainContentCoordinator
        let tabManager: QueryTabManager
        let tabId: UUID

        func cellMenuItems(row: Int, dataColumn: Int) -> [NSMenuItem] {
            let model = coordinator.gridModel(forTab: tabId)
            guard let adapter = coordinator.dataGridEntries[tabId]?.adapter,
                  let rowID = model.rowID(at: row),
                  let position = model.columns.displayPosition(ofDataIndex: dataColumn),
                  let column = model.columns.column(at: position) else { return [] }
            return adapter.gridCellMenuItems(for: rowID, column: column)
        }

        func filterMenuItem(row: Int, dataColumn: Int) -> NSMenuItem? {
            cellMenuItems(row: row, dataColumn: dataColumn).first { $0.title == String(localized: "Filter") }
        }
    }

    private func makeHarness(tabType: TabType = .table, editsFirstRowStatus: Bool = false) -> Harness {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
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
        if editsFirstRowStatus { editStatusOfFirstRow(coordinator.changeManager(forTab: tab.id)) }
        return Harness(coordinator: coordinator, tabManager: tabManager, tabId: tab.id)
    }

    private func editStatusOfFirstRow(_ changes: DataChangeManager) {
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
    }

    private func conditions(_ filters: [TableFilter]?) -> [String] {
        (filters ?? []).map { "\($0.columnName) \($0.filterOperator.rawValue) \($0.value)" }
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

        let item = try #require(harness.filterMenuItem(row: 1, dataColumn: 1))

        #expect(item.submenu?.items.map(\.title) == ["status = “open”", "status != “open”"])
    }

    @Test("Choosing a condition re-queries the table with it and shows the filter bar")
    func choosingAConditionRequeries() throws {
        let harness = makeHarness()
        defer {
            clearSavedFilters(harness)
            harness.coordinator.teardown()
        }
        let item = try #require(harness.filterMenuItem(row: 0, dataColumn: 1))

        item.submenu?.performActionForItem(at: 0)

        let state = try #require(harness.tabManager.tabs.first { $0.id == harness.tabId }?.filterState)
        let applied = try #require(state.applied)
        #expect(applied.filters.map(\.columnName) == ["status"])
        #expect(applied.filters.map(\.filterOperator) == [.equal])
        #expect(applied.filters.map(\.value) == ["paid"])
        #expect(state.filters.map(\.id) == applied.filters.map(\.id))
        #expect(state.status == .applied)
        #expect(state.isVisible)
    }

    @Test("A second condition narrows the first rather than replacing it")
    func secondConditionNarrows() throws {
        let harness = makeHarness()
        defer {
            clearSavedFilters(harness)
            harness.coordinator.teardown()
        }

        try #require(harness.filterMenuItem(row: 0, dataColumn: 1))
            .submenu?.performActionForItem(at: 1)
        try #require(harness.filterMenuItem(row: 1, dataColumn: 0))
            .submenu?.performActionForItem(at: 2)

        let state = try #require(harness.tabManager.tabs.first { $0.id == harness.tabId }?.filterState)
        #expect(conditions(state.applied?.filters) == ["status != paid", "id > 2"])
        #expect(state.applied?.logicMode == .and)
        #expect(state.filterLogicMode == .and)
    }

    @Test("A row applied alone under Match any keeps running, and a cell's condition joins it under Match all")
    func conditionJoinsTheRowAppliedAlone() throws {
        let harness = makeHarness()
        defer {
            clearSavedFilters(harness)
            harness.coordinator.teardown()
        }
        let notOpen = TestFixtures.makeTableFilter(column: "status", op: .notEqual, value: "open")
        let second = TestFixtures.makeTableFilter(column: "id", op: .equal, value: "2")
        harness.tabManager.mutate(tabId: harness.tabId) {
            $0.filterState.filters = [notOpen, second]
            $0.filterState.filterLogicMode = .or
        }
        harness.coordinator.filterCoordinator.applyFilterAlone(notOpen.id)
        try #require(harness.tabManager.tabs.first { $0.id == harness.tabId }?.filterState.aloneFilterID == notOpen.id)

        try #require(harness.filterMenuItem(row: 0, dataColumn: 0))
            .submenu?.performActionForItem(at: 0)

        let state = try #require(harness.tabManager.tabs.first { $0.id == harness.tabId }?.filterState)
        #expect(conditions(state.applied?.filters) == ["status != open", "id = 1"])
        #expect(state.applied?.logicMode == .and)
        #expect(state.aloneFilterID == nil)
        #expect(state.filterLogicMode == .and)
        #expect(state.filters.map(\.isEnabled) == [true, false, true])
    }

    // Pretends an alert is already up, which `confirmDiscardChangesIfNeeded` answers false to once there are edits.
    @Test("Nothing changes while the discard alert is unanswered")
    func declinedDiscardChangesNothing() throws {
        let harness = makeHarness(editsFirstRowStatus: true)
        defer { harness.coordinator.teardown() }
        #expect(harness.coordinator.changeManager.hasChanges)
        let item = try #require(harness.filterMenuItem(row: 1, dataColumn: 1))
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

        #expect(harness.filterMenuItem(row: 0, dataColumn: 1) == nil)
    }

    @Test("An edited cell has no Filter item, because the server does not hold its value")
    func editedCellHasNoItem() {
        let harness = makeHarness(editsFirstRowStatus: true)
        defer { harness.coordinator.teardown() }

        #expect(harness.filterMenuItem(row: 0, dataColumn: 1) == nil)
        #expect(harness.filterMenuItem(row: 0, dataColumn: 0) != nil)
        #expect(harness.filterMenuItem(row: 1, dataColumn: 1) != nil)
    }

    @Test("The Filter item sits just before Highlight in the cell items the adapter adds")
    func filterComesBeforeHighlight() throws {
        let harness = makeHarness()
        defer { harness.coordinator.teardown() }

        let titles = harness.cellMenuItems(row: 0, dataColumn: 1).map(\.title)

        let filterIndex = try #require(titles.firstIndex(of: String(localized: "Filter")))
        #expect(titles.indices.contains(filterIndex + 1))
        #expect(titles.dropFirst(filterIndex + 1).first == String(localized: "Highlight"))
    }
}
