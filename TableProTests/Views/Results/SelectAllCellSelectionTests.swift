//
//  SelectAllCellSelectionTests.swift
//  TableProTests
//
//  Cmd+A selects the rows, and nothing else: no cell rectangle, no cell cursor, and no heading
//  marked as picked. It used to build a cell rectangle over the whole grid, which is the same shape
//  a heading click builds, so the entire heading row painted as selected and a cell cursor sat on
//  the first cell of a selection that owns every row.
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
    let header: SortableHeaderView
    let published: RowSelectionBox
    let rowCount: Int
    let columnCount: Int

    /// What the headings actually show, which is the channel the reported defect appeared on.
    var pickedHeadings: [Int] {
        tableView.tableColumns.enumerated().compactMap { index, column in
            (column.headerCell as? SortableHeaderCell)?.isColumnSelected == true ? index : nil
        }
    }

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

        header = SortableHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        header.coordinator = coordinator
        tableView.headerView = header

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
        /// What `installSelectionOverlay` wires in the app. Without it the controller has no table
        /// view, so `reloadColumns` reaches no heading and every assertion about the heading row
        /// passes for the wrong reason.
        coordinator.selectionController.tableView = tableView
        coordinator.selectionController.coordinator = coordinator

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

    @Test("Command A leaves no cell selection behind")
    func selectAllLeavesNoCellSelection() {
        let grid = SelectAllGrid()

        grid.tableView.selectAll(nil)

        #expect(grid.coordinator.selectionController.isEmpty)
    }

    /// The reported defect. A whole-grid rectangle is geometrically what a heading click builds, so
    /// every heading read as picked and the whole row painted in the selection colour.
    @Test("Command A marks no heading as picked")
    func selectAllPicksNoHeading() {
        let grid = SelectAllGrid()

        grid.tableView.selectAll(nil)

        #expect(grid.coordinator.selectionController.selectedFullColumns().isEmpty)
        #expect(grid.pickedHeadings.isEmpty)
    }

    /// A heading picked first has to stand down, or Cmd+A leaves the old tint over a row selection.
    @Test("Command A clears a heading picked before it")
    func selectAllClearsAPickedHeading() {
        let grid = SelectAllGrid()
        grid.coordinator.selectionController.selectEntireColumn(1, totalRows: grid.rowCount)
        #expect(!grid.pickedHeadings.isEmpty)

        grid.tableView.selectAll(nil)

        #expect(grid.pickedHeadings.isEmpty)
    }

    /// CLAUDE.md's rule for the grid: a whole-row selection owns it, and no cell cursor survives it.
    @Test("Command A leaves no cell cursor")
    func selectAllLeavesNoCellCursor() {
        let grid = SelectAllGrid()
        grid.tableView.focusedRow = 2
        grid.tableView.focusedColumn = 2

        grid.tableView.selectAll(nil)

        #expect(grid.tableView.focusedRow == -1)
        #expect(grid.tableView.focusedColumn == -1)
    }

    @Test("Command A still selects every row")
    func selectAllSelectsEveryRow() {
        let grid = SelectAllGrid()

        grid.tableView.selectAll(nil)

        #expect(grid.tableView.selectedRowIndexes == IndexSet(integersIn: 0..<grid.rowCount))
    }

    /// Escape used to have a rectangle to cancel after Cmd+A. With none left it has to answer the
    /// row selection instead, or Cmd+A becomes the one selection Escape cannot give back.
    @Test("Escape after Command A deselects every row")
    func escapeAfterSelectAllDeselectsEveryRow() {
        let grid = SelectAllGrid()
        grid.tableView.selectAll(nil)
        #expect(!grid.tableView.selectedRowIndexes.isEmpty)

        grid.tableView.cancelOperation(nil)

        #expect(grid.tableView.selectedRowIndexes.isEmpty)
    }

    /// Every consumer of the published set, the status bar and the tab's stored selection included,
    /// still sees all the rows.
    @Test("Command A still publishes every row to the owner")
    func selectAllStillPublishesEveryRow() {
        let grid = SelectAllGrid()

        grid.tableView.selectAll(nil)

        #expect(grid.published.value == Set(0..<grid.rowCount))
    }

    /// Shift+Space widens the selection to the whole of every row it touches, so after it no single
    /// cell is the current one. The cursor used to survive, leaving a cell ring inside a selection
    /// that owns whole rows.
    @Test("Shift+Space leaves no cell cursor")
    func rowWideningLeavesNoCellCursor() {
        let grid = SelectAllGrid()
        let seed = GridCoord(row: 2, displayColumn: 1)
        grid.coordinator.selectionController.update(.single(GridRect(cell: seed), anchor: seed, active: seed))
        grid.tableView.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        grid.tableView.focusedRow = 2
        grid.tableView.focusedColumn = 2

        grid.tableView.selectRowsIntersectingSelection()

        #expect(grid.tableView.focusedRow == -1)
        #expect(grid.tableView.focusedColumn == -1)
        #expect(grid.coordinator.selectionController.selectedFullColumns().isEmpty)
    }

    @Test("an empty grid falls through to the table view's own select all")
    func emptyGridFallsThrough() {
        let grid = SelectAllGrid(rowCount: 0)

        grid.tableView.selectAll(nil)

        #expect(grid.coordinator.selectionController.isEmpty)
    }
}
