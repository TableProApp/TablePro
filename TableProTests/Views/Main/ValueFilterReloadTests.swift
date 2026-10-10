//
//  ValueFilterReloadTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class ReloadLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
struct ValueFilterReloadTests {
    private static func rows(_ values: [[String]], columns: [String] = ["id", "name"]) -> TableRows {
        TableRows.from(
            queryRows: values.map { row in row.map { PluginCellValue.text($0) } },
            columns: columns,
            columnTypes: Array(repeating: .text(rawType: nil), count: columns.count)
        )
    }

    private func makeCoordinator(tabType: TabType = .table) -> (MainContentCoordinator, UUID) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        let tab = QueryTab(title: "users", query: "SELECT id, name FROM users", tabType: tabType, tableName: "users")
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        coordinator.setActiveTableRows(Self.rows([["1", "Alice"], ["2", "Bob"]]), for: tab.id)
        return (coordinator, tab.id)
    }

    private func filterName(_ names: Set<String>, at column: Int = 1, in coordinator: MainContentCoordinator, tabId: UUID) {
        var state = GridValueFilterState()
        state.set(ColumnValueFilter(selectedValues: names, includesNull: false), columnName: "name", forColumn: column)
        coordinator.setValueFilter(state, forTab: tabId)
    }

    private func valueFilter(_ coordinator: MainContentCoordinator, _ tabId: UUID) -> GridValueFilterState? {
        coordinator.tabManager.tabs.first { $0.id == tabId }?.valueFilter
    }

    @Test("Reading the same source again keeps the value filter and applies it to the fresh rows")
    func sameSourceKeepsTheFilter() {
        let (coordinator, tabId) = makeCoordinator()
        defer { coordinator.teardown() }
        filterName(["Bob"], in: coordinator, tabId: tabId)

        coordinator.setActiveTableRows(
            Self.rows([["1", "Alice"], ["2", "Bob"], ["3", "Bob"]]),
            for: tabId,
            viewport: .keepPlace,
            source: .sameSource
        )

        #expect(valueFilter(coordinator, tabId)?.isActive == true)
        #expect(coordinator.displayIDs(forTab: tabId) == [.existing(1), .existing(2)])
    }

    @Test("A row saved out of the filter's values drops out when the rows are read again")
    func editedOutRowDropsOnReload() {
        let (coordinator, tabId) = makeCoordinator()
        defer { coordinator.teardown() }
        filterName(["Bob"], in: coordinator, tabId: tabId)

        coordinator.setActiveTableRows(Self.rows([["1", "Alice"], ["2", "Robert"]]), for: tabId, source: .sameSource)

        #expect(valueFilter(coordinator, tabId)?.isActive == true)
        #expect(coordinator.displayIDs(forTab: tabId)?.isEmpty == true)
    }

    @Test("The filter follows its column when the rows come back with the columns moved")
    func filterFollowsAMovedColumn() {
        let (coordinator, tabId) = makeCoordinator()
        defer { coordinator.teardown() }
        filterName(["Bob"], in: coordinator, tabId: tabId)

        coordinator.setActiveTableRows(
            Self.rows([["1", "a@x", "Alice"], ["2", "b@x", "Bob"]], columns: ["id", "email", "name"]),
            for: tabId,
            source: .sameSource
        )

        #expect(valueFilter(coordinator, tabId)?.columnName(forColumn: 2) == "name")
        #expect(valueFilter(coordinator, tabId)?.isActive(column: 1) == false)
        #expect(coordinator.displayIDs(forTab: tabId) == [.existing(1)])
    }

    @Test("A mounted grid takes the moved filter, so its own prune cannot write the old copy back")
    func mountedGridAdoptsTheCarriedFilter() {
        let (coordinator, tabId) = makeCoordinator()
        defer { coordinator.teardown() }
        let delegate = DataTabGridDelegate()
        let grid = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: delegate,
            layoutPersister: ReloadLayoutPersister()
        )
        delegate.dataGridAttach(tableViewCoordinator: grid)
        coordinator.dataTabDelegate = delegate
        grid.tableRowsProvider = { [weak coordinator] in
            coordinator?.tabSessionRegistry.tableRows(for: tabId) ?? TableRows()
        }
        grid.valueFilterBinding = Binding(
            get: { coordinator.tabManager.tabs.first { $0.id == tabId }?.valueFilter ?? GridValueFilterState() },
            set: { coordinator.setValueFilter($0, forTab: tabId) }
        )
        filterName(["Bob"], in: coordinator, tabId: tabId)
        grid.adoptValueFilter(valueFilter(coordinator, tabId) ?? GridValueFilterState())

        coordinator.setActiveTableRows(
            Self.rows([["1", "a@x", "Alice"], ["2", "b@x", "Bob"]], columns: ["id", "email", "name"]),
            for: tabId,
            source: .sameSource
        )

        #expect(valueFilter(coordinator, tabId)?.isActive(column: 2) == true)
        #expect(grid.valueFilterState == valueFilter(coordinator, tabId))
        withExtendedLifetime((delegate, grid)) {}
    }

    @Test("A new source still clears the value filter")
    func newSourceClearsTheFilter() {
        let (coordinator, tabId) = makeCoordinator()
        defer { coordinator.teardown() }
        filterName(["Bob"], in: coordinator, tabId: tabId)

        coordinator.setActiveTableRows(Self.rows([["1", "Alice"], ["2", "Bob"]]), for: tabId)

        #expect(valueFilter(coordinator, tabId)?.isActive == false)
    }

    @Test("A new result on a query tab drops the grid sort, a re-read keeps it")
    func queryTabSortGoesWithItsSource() {
        let (coordinator, tabId) = makeCoordinator(tabType: .query)
        defer { coordinator.teardown() }
        let sorted = SortState(columns: [SortColumn(columnIndex: 1, direction: .ascending)], source: .user)
        coordinator.tabManager.mutate(tabId: tabId) { $0.sortState = sorted }

        coordinator.setActiveTableRows(Self.rows([["1", "Alice"]]), for: tabId, source: .sameSource)
        #expect(coordinator.tabManager.tabs.first { $0.id == tabId }?.sortState == sorted)

        coordinator.setActiveTableRows(Self.rows([["1", "Alice"]]), for: tabId)
        #expect(coordinator.tabManager.tabs.first { $0.id == tabId }?.sortState.columns.isEmpty == true)
    }

    @Test("A table tab keeps its sort through a new install, because its query carries it")
    func tableTabSortStays() {
        let (coordinator, tabId) = makeCoordinator()
        defer { coordinator.teardown() }
        let sorted = SortState(columns: [SortColumn(columnIndex: 1, direction: .descending)], source: .user)
        coordinator.tabManager.mutate(tabId: tabId) { $0.sortState = sorted }

        coordinator.setActiveTableRows(Self.rows([["1", "Alice"]]), for: tabId)

        #expect(coordinator.tabManager.tabs.first { $0.id == tabId }?.sortState == sorted)
    }

    @Test("Sorting rows held in place keeps the value filter")
    func heldRowSortKeepsTheFilter() throws {
        let (coordinator, tabId) = makeCoordinator(tabType: .query)
        defer { coordinator.teardown() }
        let rows = Self.rows([["2", "Bob"], ["1", "Alice"], ["3", "Bob"]])
        let held = ResultSet(label: "Result 1", tableRows: rows)
        coordinator.tabManager.mutate(tabId: tabId) { $0.display.replaceUnpinnedResults(with: [held]) }
        coordinator.setActiveTableRows(rows, for: tabId)
        filterName(["Bob"], in: coordinator, tabId: tabId)

        coordinator.handleSortStateChanged(SortState(columns: [SortColumn(columnIndex: 0, direction: .ascending)], source: .user))

        #expect(valueFilter(coordinator, tabId)?.isActive == true)
        let shown = try #require(coordinator.displayIDs(forTab: tabId))
        let tableRows = coordinator.tabSessionRegistry.tableRows(for: tabId)
        #expect(shown.compactMap { tableRows.index(of: $0).map { tableRows.rows[$0][0].asText } } == ["2", "3"])
    }

    @Test("Choosing the result already on screen changes nothing")
    func reselectingTheActiveResultIsANoOp() {
        let (coordinator, tabId) = makeCoordinator(tabType: .query)
        defer { coordinator.teardown() }
        let first = ResultSet(label: "first", tableRows: Self.rows([["1", "Alice"], ["2", "Bob"]]))
        let second = ResultSet(label: "second", tableRows: Self.rows([["9", "Zoe"]]))
        coordinator.tabManager.mutate(tabId: tabId) { tab in
            tab.display.resultSets = [first, second]
            tab.display.activeResultSetId = first.id
        }
        filterName(["Bob"], in: coordinator, tabId: tabId)

        coordinator.switchActiveResultSet(to: first.id, in: tabId)

        #expect(valueFilter(coordinator, tabId)?.isActive == true)
        #expect(coordinator.tabManager.tabs.first { $0.id == tabId }?.display.activeResultSetId == first.id)
    }

    @Test("Pointing a tab at another table drops its value filter")
    func retargetDropsTheFilter() throws {
        let (coordinator, tabId) = makeCoordinator()
        defer { coordinator.teardown() }
        filterName(["Bob"], in: coordinator, tabId: tabId)

        try coordinator.tabManager.replaceTabContent(tableName: "orders")

        #expect(valueFilter(coordinator, tabId)?.isActive == false)
    }
}
