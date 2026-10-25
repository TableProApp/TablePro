//
//  RowEditingCoordinatorJsonModeTests.swift
//  TableProTests
//
//  A row command points the grid at the row it just touched. JSON mode reads that same selection
//  as "show only these rows", so writing it there collapses the document (#2251).
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct RowEditingCoordinatorJsonModeTests {
    private let fixture = CoordinatorFixture()

    private func makeCoordinator(mode: ResultsViewMode) -> MainContentCoordinator {
        let tabManager = fixture.tabManager
        let coordinator = fixture.coordinator
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
        coordinator.gridModel(forTab: tab.id).setValueFilter(filter)
        return coordinator
    }

    private func model(_ coordinator: MainContentCoordinator) throws -> DataGridModel {
        let tabId = try #require(coordinator.tabManager.selectedTabId)
        return coordinator.gridModel(forTab: tabId)
    }

    @Test("the filter narrows the display order, so the filtered delete path is the one that runs")
    func filteredPathIsReached() throws {
        let coordinator = makeCoordinator(mode: .data)
        #expect(try model(coordinator).displayedRowIDs == [.existing(1), .existing(2)])
    }

    @Test("deleting in JSON mode leaves the selection alone")
    func deleteInJsonModeDoesNotMoveTheSelection() throws {
        let coordinator = makeCoordinator(mode: .json)
        let grid = try model(coordinator)
        grid.selectRows([.existing(1), .existing(2)])

        coordinator.deleteRows([.existing(1)])

        #expect(grid.selectedRowIDs == [.existing(1), .existing(2)])
    }

    @Test("deleting in Data mode still moves the selection to the surviving neighbour")
    func deleteInDataModeMovesTheSelection() throws {
        let coordinator = makeCoordinator(mode: .data)
        let grid = try model(coordinator)
        grid.selectRows([.existing(1), .existing(2)])

        coordinator.deleteRows([.existing(1)])

        #expect(grid.selectedRowIDs == [.existing(2)])
    }

    @Test("duplicating in JSON mode leaves the selection alone")
    func duplicateInJsonModeDoesNotMoveTheSelection() throws {
        let coordinator = makeCoordinator(mode: .json)
        let grid = try model(coordinator)
        grid.selectRows([.existing(2)])

        coordinator.duplicateRow(.existing(1))

        #expect(grid.selectedRowIDs == [.existing(2)])
    }

    @Test("duplicating in Data mode still selects the new row")
    func duplicateInDataModeSelectsTheNewRow() throws {
        let coordinator = makeCoordinator(mode: .data)
        let grid = try model(coordinator)
        grid.selectRows([.existing(1)])

        coordinator.duplicateRow(.existing(1))

        #expect(grid.selection.affectedRows == IndexSet(integer: 2))
        #expect(grid.selectedRowIDs.first?.isInserted == true)
    }
}
