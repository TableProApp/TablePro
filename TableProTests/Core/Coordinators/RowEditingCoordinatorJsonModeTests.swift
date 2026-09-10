//
//  RowEditingCoordinatorJsonModeTests.swift
//  TableProTests
//
//  A row command points the grid at the row it just touched. JSON mode reads that same selection
//  as "show only these rows", so writing it there collapses the document. The filtered delete and
//  duplicate paths used to be safe only by accident, because a display order existed only while
//  the grid was mounted. Now that it survives, the guard has to be explicit. (#2251)
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("RowEditingCoordinator in JSON mode")
@MainActor
struct RowEditingCoordinatorJsonModeTests {
    private func makeCoordinator(mode: ResultsViewMode) -> MainContentCoordinator {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users")
        tab.execution.lastExecutedAt = Date()
        tab.display.resultsViewMode = mode
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [
                    [.text("1"), .text("Alice")],
                    [.text("2"), .text("Bob")],
                    [.text("3"), .text("Bob")]
                ],
                columns: ["id", "name"],
                columnTypes: [.text(rawType: nil), .text(rawType: nil)],
                hasAuthoritativeSchema: true
            ),
            for: tab.id
        )
        coordinator.changeManager.primaryKeyColumns = ["id"]

        var filter = GridValueFilterState()
        filter.set(
            ColumnValueFilter(selectedValues: ["Bob"], includesNull: false),
            columnName: "name",
            forColumn: 1
        )
        coordinator.setValueFilter(filter, forTab: tab.id)
        return coordinator
    }

    @Test("the filter narrows the display order, so the filtered delete path is the one that runs")
    func filteredPathIsReached() {
        let coordinator = makeCoordinator(mode: .data)
        #expect(coordinator.activeGridDisplayIDs == [.existing(1), .existing(2)])
    }

    @Test("deleting in JSON mode leaves the selection alone")
    func deleteInJsonModeDoesNotMoveTheSelection() {
        let coordinator = makeCoordinator(mode: .json)
        coordinator.selectionState.indices = [0, 1]

        coordinator.deleteSelectedRows(indices: [0])

        #expect(coordinator.selectionState.indices == [0, 1])
    }

    @Test("deleting in Data mode still moves the selection to the surviving neighbour")
    func deleteInDataModeMovesTheSelection() {
        let coordinator = makeCoordinator(mode: .data)
        coordinator.selectionState.indices = [0, 1]

        coordinator.deleteSelectedRows(indices: [0])

        #expect(coordinator.selectionState.indices == [0])
    }

    @Test("duplicating in JSON mode leaves the selection alone")
    func duplicateInJsonModeDoesNotMoveTheSelection() {
        let coordinator = makeCoordinator(mode: .json)
        coordinator.selectionState.indices = [1]

        coordinator.duplicateSelectedRow(index: 0)

        #expect(coordinator.selectionState.indices == [1])
    }

    @Test("duplicating in Data mode still selects the new row")
    func duplicateInDataModeSelectsTheNewRow() {
        let coordinator = makeCoordinator(mode: .data)
        coordinator.selectionState.indices = [0]

        coordinator.duplicateSelectedRow(index: 0)

        #expect(coordinator.selectionState.indices == [2])
    }
}
