//
//  DataGridView+Editing.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

extension TableViewCoordinator {
    enum EditEligibility {
        case editable(value: String)
        case blocked
    }

    func editEligibility(row: Int, columnIndex: Int) -> EditEligibility {
        guard isEditable else { return .blocked }
        let tableRows = tableRowsProvider()
        guard row >= 0, columnIndex >= 0, columnIndex < tableRows.columns.count else { return .blocked }
        guard !changeManager.isRowDeleted(row) else { return .blocked }

        guard isColumnWritable(tableRows.columns[columnIndex]) else { return .blocked }

        if columnIndex < tableRows.columnTypes.count {
            let ct = tableRows.columnTypes[columnIndex]
            if ct.isBlobType {
                return .blocked
            }
        }

        guard cellTypedValue(at: row, column: columnIndex).asBytes == nil else { return .blocked }

        let value: String
        if let displayRow = displayRow(at: row),
           columnIndex < displayRow.values.count,
           let raw = displayRow.values[columnIndex].asText {
            value = raw
        } else {
            value = ""
        }
        return .editable(value: value)
    }

    /// Whether the app is allowed to send a value for this column at all, which is a narrower
    /// question than whether the cell takes the inline editor: a BLOB cell refuses the editor and
    /// still accepts NULL from the Set Value menu. The menu offered its items on a column no
    /// statement can carry, so Set NULL on a MongoDB `_id`, a generated column or a
    /// `GENERATED ALWAYS AS IDENTITY` column marked the row edited and then wrote nothing.
    func isColumnWritable(_ columnName: String) -> Bool {
        guard !changeManager.generatedColumns.contains(columnName) else { return false }
        let immutable = databaseType.map { PluginManager.shared.immutableColumns(for: $0) } ?? []
        return !immutable.contains(columnName)
    }

    func canStartInlineEdit(row: Int, columnIndex: Int) -> Bool {
        if case .editable = editEligibility(row: row, columnIndex: columnIndex) {
            return true
        }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        false
    }

    /// A grid that will not take a keystroke and says nothing reads as broken. When the refusal has
    /// a reason the pointer already carries it as the grid's tooltip, and the beep is AppKit's own
    /// way of saying the attempt was heard and declined.
    func refuseEditIfExplained() {
        guard !isEditable, editRefusalMessage != nil else { return }
        NSSound.beep()
    }

    func beginCellEdit(row: Int, tableColumnIndex: Int) {
        guard let tableView else { return }
        guard tableColumnIndex >= 0, tableColumnIndex < tableView.numberOfColumns else { return }
        let column = tableView.tableColumns[tableColumnIndex]
        guard column.identifier != ColumnIdentitySchema.rowNumberIdentifier else { return }
        guard let columnIndex = dataColumnIndex(from: column.identifier) else { return }
        guard case .editable(let value) = editEligibility(row: row, columnIndex: columnIndex) else {
            refuseEditIfExplained()
            return
        }
        showOverlayEditor(
            tableView: tableView,
            row: row,
            column: tableColumnIndex,
            columnIndex: columnIndex,
            value: value
        )
    }

    // MARK: - Overlay Editor

    func showOverlayEditor(tableView: NSTableView, row: Int, column: Int, columnIndex: Int, value: String) {
        if overlayEditor == nil {
            overlayEditor = CellOverlayEditor()
        }
        guard let editor = overlayEditor else { return }

        editor.onRemove = { [weak self] in
            self?.flushPendingCellPresentationRefresh()
        }
        editor.onCommit = { [weak self] row, columnIndex, newValue in
            self?.commitCellEdit(row: row, columnIndex: columnIndex, newValue: newValue)
        }
        editor.onMovement = { [weak self] row, column, movement in
            self?.handleOverlayMovement(row: row, column: column, movement: movement)
        }
        overlayViewer?.dismiss()
        editor.show(in: tableView, row: row, column: column, columnIndex: columnIndex, value: value)
    }

    func showOverlayViewer(tableView: NSTableView, row: Int, column: Int, columnIndex: Int, value: String) {
        if overlayViewer == nil {
            overlayViewer = CellOverlayViewer()
        }
        guard let viewer = overlayViewer else { return }
        viewer.onRemove = { [weak self] in
            self?.flushPendingCellPresentationRefresh()
        }
        overlayEditor?.dismiss(commit: false)
        viewer.show(in: tableView, row: row, column: column, columnIndex: columnIndex, value: value)
    }

    /// The cell cursor moves with the editor, through the same `focusCell` the grid's own Tab uses.
    /// Selecting the row alone left the cursor on the column the editor came from, so closing the
    /// editor put it back where the editing was not, and it never scrolled the target row into
    /// view, so a wrap onto the row below the last visible one opened the editor off screen.
    func handleOverlayMovement(row: Int, column: Int, movement: CellEditorMovement) {
        guard let tableView = tableView as? KeyHandlingTableView,
              let target = movementTarget(from: (row, column), movement: movement, in: tableView)
        else { return }

        tableView.focusCell(row: target.row, column: target.column)

        guard let targetColumnIndex = DataGridView.dataColumnIndex(
                for: target.column,
                in: tableView,
                schema: identitySchema
              ),
              targetColumnIndex >= 0,
              case .editable(let value) = editEligibility(row: target.row, columnIndex: targetColumnIndex)
        else { return }

        showOverlayEditor(
            tableView: tableView,
            row: target.row,
            column: target.column,
            columnIndex: targetColumnIndex,
            value: value
        )
    }

    /// Tab walks the presented columns and wraps onto the next row's first, Shift+Tab onto the
    /// previous row's last. Both ends are resolved rather than assumed: the window's spacers and
    /// the pool's surplus slots are attached columns too, so neither end of `tableColumns` holds a
    /// data column and a fixed position lands on a spacer that swallows the keystroke.
    ///
    /// Up and Down hold the column and step one row, and neither wraps: a column is a column of one
    /// kind of value, so carrying the editor from the last row round to the first is a jump the
    /// user did not ask for.
    func movementTarget(
        from cell: (row: Int, column: Int),
        movement: CellEditorMovement,
        in tableView: NSTableView
    ) -> (row: Int, column: Int)? {
        switch movement {
        case .tab:
            if let next = nextPresentedColumnIndex(after: cell.column) {
                return (cell.row, next)
            }
            guard cell.row + 1 < tableView.numberOfRows, let first = firstPresentedColumnIndex() else { return nil }
            return (cell.row + 1, first)
        case .backtab:
            if let previous = previousPresentedColumnIndex(before: cell.column) {
                return (cell.row, previous)
            }
            guard cell.row > 0, let last = lastPresentedColumnIndex() else { return nil }
            return (cell.row - 1, last)
        case .up:
            guard cell.row > 0 else { return nil }
            return (cell.row - 1, cell.column)
        case .down:
            guard cell.row + 1 < tableView.numberOfRows else { return nil }
            return (cell.row + 1, cell.column)
        }
    }
}
