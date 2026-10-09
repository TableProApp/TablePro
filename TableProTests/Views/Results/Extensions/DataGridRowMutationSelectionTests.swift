//
//  DataGridRowMutationSelectionTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class RowMutationLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class RowMutationStore {
    var tableRows: TableRows

    init(_ tableRows: TableRows) {
        self.tableRows = tableRows
    }
}

@MainActor
private struct RowMutationGrid {
    let coordinator: TableViewCoordinator
    let store: RowMutationStore
    let tableView: KeyHandlingTableView
}

@MainActor
struct DataGridRowMutationSelectionTests {
    private static let columns = ["id", "name"]
    private static let columnTypes: [ColumnType] = [.integer(rawType: "INT"), .text(rawType: "TEXT")]

    private func makeGrid(rowCount: Int) -> RowMutationGrid {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: RowMutationLayoutPersister()
        )
        let store = RowMutationStore(TableRows.from(
            queryRows: (0..<rowCount).map { [.text("\($0)"), .text("name-\($0)")] },
            columns: Self.columns,
            columnTypes: Self.columnTypes
        ))
        coordinator.tableRowsProvider = { store.tableRows }
        coordinator.tableRowsMutator = { mutation in mutation(&store.tableRows) }

        let tableView = KeyHandlingTableView()
        tableView.coordinator = coordinator
        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView
        coordinator.rebuildColumnMetadataCache(from: store.tableRows)
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: ColumnIdentitySchema(columns: Self.columns),
            columnTypes: Self.columnTypes,
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 100 }
        )
        coordinator.updateCache()
        tableView.reloadData()
        return RowMutationGrid(coordinator: coordinator, store: store, tableView: tableView)
    }

    private static func block(rows: ClosedRange<Int>) -> GridSelection {
        .single(
            GridRect(rows: rows, columns: 0...1),
            anchor: GridCoord(row: rows.lowerBound, displayColumn: 0),
            active: GridCoord(row: rows.upperBound, displayColumn: 1)
        )
    }

    private func selectedRecords(_ coordinator: TableViewCoordinator) -> [RowID] {
        coordinator.selectionController.selection.affectedRows.compactMap { coordinator.displayRow(at: $0)?.id }
    }

    @Test("discarding an inserted row above the selection keeps the selection on the same records")
    func discardingInsertedRowShiftsSelection() {
        let grid = makeGrid(rowCount: 5)
        let coordinator = grid.coordinator
        let insertedID = RowID.inserted(UUID())
        coordinator.applyDelta(coordinator.tableRowsMutator { rows in
            rows.insertInsertedRow(at: 1, id: insertedID, values: [.text("9"), .text("new")])
        })
        coordinator.selectionController.update(Self.block(rows: 3...4))
        #expect(selectedRecords(coordinator) == [.existing(2), .existing(3)])

        coordinator.applyDelta(coordinator.tableRowsMutator { rows in rows.remove(rowIDs: [insertedID]) })

        #expect(coordinator.selectionController.selection.rectangles == [GridRect(rows: 2...3, columns: 0...1)])
        #expect(selectedRecords(coordinator) == [.existing(2), .existing(3)])
        #expect(grid.tableView.numberOfRows == 5)
    }

    @Test("a row added above the selection moves the selection down with its records")
    func insertingRowAboveShiftsSelection() {
        let grid = makeGrid(rowCount: 5)
        let coordinator = grid.coordinator
        coordinator.selectionController.update(Self.block(rows: 1...2))

        coordinator.applyDelta(coordinator.tableRowsMutator { rows in
            rows.insertInsertedRow(at: 0, values: [.text("9"), .text("new")])
        })

        #expect(coordinator.selectionController.selection.rectangles == [GridRect(rows: 2...3, columns: 0...1)])
        #expect(selectedRecords(coordinator) == [.existing(1), .existing(2)])
        #expect(grid.tableView.numberOfRows == 6)
    }

    @Test("under a value filter a row change drops the cell selection instead of shifting it")
    func valueFilterDropsSelection() {
        let grid = makeGrid(rowCount: 5)
        let coordinator = grid.coordinator
        coordinator.applyValueFilter(
            ColumnValueFilter(selectedValues: ["1", "2", "3"], includesNull: false),
            columnName: "id",
            forColumn: 0
        )
        coordinator.selectionController.update(Self.block(rows: 0...1))
        #expect(!coordinator.selectionController.isEmpty)

        coordinator.applyDelta(coordinator.tableRowsMutator { rows in rows.remove(rowIDs: [.existing(4)]) })

        #expect(coordinator.selectionController.isEmpty)
        #expect(grid.tableView.numberOfRows == coordinator.cachedRowCount)
    }

    private func focus(row: Int, dataColumn: Int, in grid: RowMutationGrid) {
        grid.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        grid.tableView.focusedRow = row
        grid.tableView.focusedColumn = grid.coordinator.tableColumnIndex(for: dataColumn) ?? -1
    }

    /// AppKit shifts the selected rows on an insert without posting a selection change, so the
    /// cursor stayed on the old index: the focus ring sat on another record and Paste anchored there.
    @Test("a row added above the cursor moves the cursor with its record")
    func insertingRowAboveShiftsCursor() {
        let grid = makeGrid(rowCount: 5)
        focus(row: 2, dataColumn: 1, in: grid)
        #expect(grid.tableView.pasteAnchorCell()?.row == 2)

        grid.coordinator.applyDelta(grid.coordinator.tableRowsMutator { rows in
            rows.insertInsertedRow(at: 0, values: [.text("9"), .text("new")])
        })

        #expect(grid.tableView.focusedRow == 3)
        #expect(grid.tableView.focusedRow == grid.tableView.selectedRow)
        #expect(grid.coordinator.displayRow(at: grid.tableView.focusedRow)?.id == .existing(2))
        #expect(grid.tableView.pasteAnchorCell()?.row == 3)
    }

    @Test("a row added below the cursor leaves it where it is")
    func insertingRowBelowKeepsCursor() {
        let grid = makeGrid(rowCount: 5)
        focus(row: 2, dataColumn: 1, in: grid)

        grid.coordinator.applyDelta(grid.coordinator.tableRowsMutator { rows in
            rows.insertInsertedRow(at: 4, values: [.text("9"), .text("new")])
        })

        #expect(grid.tableView.focusedRow == 2)
        #expect(grid.coordinator.displayRow(at: grid.tableView.focusedRow)?.id == .existing(2))
    }

    @Test("removing a row above the cursor moves it up, and removing its own row clears it")
    func removingRowsShiftsOrClearsCursor() {
        let grid = makeGrid(rowCount: 5)
        focus(row: 3, dataColumn: 1, in: grid)

        grid.coordinator.applyDelta(grid.coordinator.tableRowsMutator { rows in rows.remove(rowIDs: [.existing(0)]) })

        #expect(grid.tableView.focusedRow == 2)
        #expect(grid.tableView.focusedRow == grid.tableView.selectedRow)
        #expect(grid.coordinator.displayRow(at: grid.tableView.focusedRow)?.id == .existing(3))

        grid.coordinator.applyDelta(grid.coordinator.tableRowsMutator { rows in rows.remove(rowIDs: [.existing(3)]) })

        #expect(grid.tableView.focusedRow == -1)
        #expect(grid.tableView.pasteAnchorCell()?.row == nil)
    }
}
