//
//  SelectAllCellSelectionTests.swift
//  TableProTests
//
//  Cmd+A builds a cell rectangle over the whole grid and then selects every row. The row write has
//  to be marked programmatic: `tableViewSelectionDidChange` answers an unmarked write over a live
//  cell selection by clearing it, so Cmd+A used to destroy the rectangle it had just built.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class StubSelectAllPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class RowSelectionBox {
    var value: Set<Int> = []

    func binding() -> Binding<Set<Int>> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}

@MainActor
private struct SelectAllGrid {
    let tableView: KeyHandlingTableView
    let coordinator: TableViewCoordinator
    let published: RowSelectionBox
    let rowCount: Int
    let columnCount: Int

    init(rowCount: Int = 8, dataColumns: Int = 4) {
        self.rowCount = rowCount
        self.columnCount = dataColumns
        let columns = (0..<dataColumns).map { "col\($0)" }
        let rows = (0..<rowCount).map { row in columns.map { PluginCellValue.text("\($0)-\(row)") } }
        let tableRows = TableRows.from(
            queryRows: rows,
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: dataColumns)
        )

        /// A real binding, not `.constant([])`, which swallows every write and would leave the
        /// suite unable to see whether the row set still reaches the tab.
        let box = RowSelectionBox()
        published = box
        coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: box.binding(),
            delegate: nil,
            layoutPersister: StubSelectAllPersister()
        )
        coordinator.tableRowsProvider = { tableRows }

        tableView = KeyHandlingTableView()
        tableView.coordinator = coordinator
        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        tableView.rowHeight = 22
        tableView.allowsMultipleSelection = true

        let rowNumberColumn = DataGridView.makeRowNumberColumn()
        tableView.addTableColumn(rowNumberColumn)

        coordinator.tableView = tableView
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        /// The pool is what attaches the data columns and what `presentsColumn` answers from, so a
        /// harness that adds columns by hand presents none of them and `selectAll` falls through to
        /// AppKit's own path, which selects every row and builds no cell rectangle at all.
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: dataColumns),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 100 }
        )
        coordinator.invalidateColumnIndexCache()
        coordinator.updateCache()
        tableView.reloadData()
    }
}

@Suite("KeyHandlingTableView.selectAll")
@MainActor
struct SelectAllCellSelectionTests {
    /// `selectAll` falls through to AppKit's own when the grid presents no data columns, and that
    /// path selects every row too, so without this the suite would pass over a harness that never
    /// exercised the cell selection at all.
    @Test("the harness presents its data columns, so selectAll takes the grid's own path")
    func harnessPresentsDataColumns() {
        let grid = SelectAllGrid()

        #expect(grid.coordinator.presentedColumnCount == grid.columnCount)
    }

    @Test("Command A leaves the cell rectangle it built in place")
    func selectAllKeepsTheCellSelection() {
        let grid = SelectAllGrid()

        grid.tableView.selectAll(nil)

        #expect(!grid.coordinator.selectionController.isEmpty)
        #expect(
            grid.coordinator.selectionController.selection.rectangles
                == [GridRect(rows: 0...(grid.rowCount - 1), columns: 0...(grid.columnCount - 1))]
        )
    }

    @Test("Command A still selects every row")
    func selectAllSelectsEveryRow() {
        let grid = SelectAllGrid()

        grid.tableView.selectAll(nil)

        #expect(grid.tableView.selectedRowIndexes == IndexSet(integersIn: 0..<grid.rowCount))
    }

    /// Escape reads the cell selection to decide whether it has anything to cancel, so it is the
    /// user-visible proof that the rectangle survived rather than an assertion about internals.
    @Test("Escape after Command A has a cell selection to cancel")
    func escapeAfterSelectAllClearsTheCellSelection() {
        let grid = SelectAllGrid()
        grid.tableView.selectAll(nil)
        #expect(!grid.coordinator.selectionController.isEmpty)

        grid.tableView.cancelOperation(nil)

        #expect(grid.coordinator.selectionController.isEmpty)
    }

    /// Marking the write programmatic suppresses the delegate's `clear()` and nothing else:
    /// `publishRowSelection` still runs, so every consumer of the published set, the status bar and
    /// the tab's stored selection included, still sees all the rows.
    @Test("Command A still publishes every row to the owner")
    func selectAllStillPublishesEveryRow() {
        let grid = SelectAllGrid()

        grid.tableView.selectAll(nil)

        #expect(grid.published.value == Set(0..<grid.rowCount))
    }

    @Test("an empty grid falls through to the table view's own select all")
    func emptyGridFallsThrough() {
        let grid = SelectAllGrid(rowCount: 0)

        grid.tableView.selectAll(nil)

        #expect(grid.coordinator.selectionController.isEmpty)
    }
}
