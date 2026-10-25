//
//  DataGridCommandScope.swift
//  TablePro
//

import Foundation

// What a command acts on. A context menu acts on the selection only when the click lands in it, else on the
// clicked cell or row (NSTableView clickedRow); the selection itself never moves.
struct DataGridCommandScope: Equatable {
    let selection: GridSelection
    // The cell a one-cell command reads: the clicked cell, else the active cell. Nil over the row numbers.
    let focus: GridCoord?
    // Opened over the row numbers, so Copy means the rows whatever shape the selection has.
    let isRowHeader: Bool

    static func current(_ selection: GridSelection) -> DataGridCommandScope {
        DataGridCommandScope(selection: selection, focus: selection.activeCell, isRowHeader: false)
    }

    static func contextMenu(
        selection: GridSelection,
        row: Int,
        displayColumn: Int?,
        columnCount: Int
    ) -> DataGridCommandScope {
        guard let displayColumn else {
            if selection.affectedRows.contains(row) {
                return DataGridCommandScope(selection: selection, focus: nil, isRowHeader: true)
            }
            guard columnCount > 0 else {
                return DataGridCommandScope(selection: .empty, focus: nil, isRowHeader: true)
            }
            let column = min(max(selection.activeCell?.displayColumn ?? 0, 0), columnCount - 1)
            let cell = GridCoord(row: row, displayColumn: column)
            let wholeRow = GridSelection(
                rectangles: [GridRect(rows: row...row, columns: 0...(columnCount - 1))],
                activeCell: cell,
                anchor: cell
            )
            return DataGridCommandScope(selection: wholeRow, focus: nil, isRowHeader: true)
        }
        let clicked = GridCoord(row: row, displayColumn: displayColumn)
        if selection.contains(clicked) {
            return DataGridCommandScope(selection: selection, focus: clicked, isRowHeader: false)
        }
        return DataGridCommandScope(selection: GridSelectionReducer.single(clicked), focus: clicked, isRowHeader: false)
    }
}

// A menu item's scope, held by identity: a reload under an open menu cannot retarget the command.
struct DataGridMenuContext {
    let selection: GridSelectionSnapshot
    let focus: GridSelectionSnapshot.Cell?
    let isRowHeader: Bool
    // Whether the menu acts on the grid's own selection, which the selection summary describes.
    let isCurrentSelection: Bool

    @MainActor
    init(_ scope: DataGridCommandScope, model: DataGridModel) {
        let rows = model.rows
        selection = GridSelectionSnapshot(scope.selection, order: model.order, rows: rows, columns: model.columns)
        focus = scope.focus.flatMap { coord in
            guard let rowID = model.rowID(at: coord.row), let column = model.columns.column(at: coord.displayColumn) else {
                return nil
            }
            return GridSelectionSnapshot.Cell(rowID: rowID, columnID: column.id)
        }
        isRowHeader = scope.isRowHeader
        isCurrentSelection = scope.selection == model.selection
    }

    @MainActor
    func scope(in model: DataGridModel) -> DataGridCommandScope {
        let rows = model.rows
        let resolved = selection.resolved(order: model.order, rows: rows, columns: model.columns)
            .clamped(rowLimit: model.rowCount, columnLimit: model.columns.count)
        let focusCoord = focus.flatMap { cell -> GridCoord? in
            guard let row = model.displayIndex(of: cell.rowID),
                  let column = model.columns.displayPosition(of: cell.columnID) else { return nil }
            return GridCoord(row: row, displayColumn: column)
        }
        return DataGridCommandScope(selection: resolved, focus: focusCoord, isRowHeader: isRowHeader)
    }
}

// A cell a command writes or reads, by identity; row is its display position when the command was resolved.
struct DataGridCommandCell: Equatable {
    let rowID: RowID
    let row: Int
    let column: DataGridColumn
}
