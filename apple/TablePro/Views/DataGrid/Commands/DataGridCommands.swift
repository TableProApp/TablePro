//
//  DataGridCommands.swift
//  TablePro
//

import AppKit
import TableProPluginKit

typealias StagedCellEntry = (value: PluginCellValue, isExpression: Bool)

// Copy, paste, Set Value, Fill Column and the row commands, over the model. Every multi-cell edit is one
// model.commit, so the owner records one undo step named for the command.
@MainActor
struct DataGridCommands {
    let model: DataGridModel
    let loader: DataGridValueLoader

    init(model: DataGridModel, loader: DataGridValueLoader = DataGridValueLoader()) {
        self.model = model
        self.loader = loader
    }

    var configuration: DataGridConfiguration { model.configuration }

    func offers(_ command: DataGridCommand) -> Bool {
        configuration.commands.contains(command)
    }

    // MARK: - Targets

    // Rows the user picked or the row a click selected, as opposed to a range of cells of any width.
    func isWholeRows(_ selection: GridSelection) -> Bool {
        !selection.isEmpty && selection.isRows
    }

    func commandCell(at coord: GridCoord) -> DataGridCommandCell? {
        guard coord.row >= 0, coord.row < model.rowCount,
              let rowID = model.rowID(at: coord.row),
              let column = model.columns.column(at: coord.displayColumn) else { return nil }
        return DataGridCommandCell(rowID: rowID, row: coord.row, column: column)
    }

    func rowIDs(_ scope: DataGridCommandScope) -> [RowID] {
        let rowCount = model.rowCount
        let rows = scope.selection.affectedRows.filteredIndexSet { $0 >= 0 && $0 < rowCount }
        return model.order.rowIDs(atDisplayIndexes: rows, in: model.rows)
    }

    // The cells Set Value, Set Cells to Value and a one-value paste write. Whole rows take the focus column on each.
    func cells(_ scope: DataGridCommandScope) -> [DataGridCommandCell] {
        let selection = scope.selection
        guard !selection.isEmpty, !scope.isRowHeader else { return [] }
        let rows = model.rows
        let rowCount = model.rowCount
        let columns = model.columns
        if isWholeRows(selection) {
            guard let focus = scope.focus, let column = columns.column(at: focus.displayColumn) else { return [] }
            return selection.affectedRows.compactMap { row in
                guard row < rowCount, let rowID = model.order.rowID(at: row, in: rows) else { return nil }
                return DataGridCommandCell(rowID: rowID, row: row, column: column)
            }
        }
        var cells: [DataGridCommandCell] = []
        for row in selection.affectedRows where row >= 0 && row < rowCount {
            guard let rowID = model.order.rowID(at: row, in: rows) else { continue }
            for position in selection.columns(in: row) {
                guard let column = columns.column(at: position) else { continue }
                cells.append(DataGridCommandCell(rowID: rowID, row: row, column: column))
            }
        }
        return cells
    }

    func focusCell(_ scope: DataGridCommandScope) -> DataGridCommandCell? {
        guard let focus = scope.focus,
              let rowID = model.rowID(at: focus.row),
              let column = model.columns.column(at: focus.displayColumn) else { return nil }
        return DataGridCommandCell(rowID: rowID, row: focus.row, column: column)
    }

    // The scope's columns in display order. Whole rows, the row numbers and one clicked cell take every presented column.
    func selectedColumns(_ scope: DataGridCommandScope) -> [DataGridColumn] {
        let selection = scope.selection
        guard !scope.isRowHeader, !isWholeRows(selection), selection.uniqueCellCount > 1 else { return model.columns.columns }
        let picked = selection.affectedColumns.compactMap { model.columns.column(at: $0) }
        return picked.isEmpty ? model.columns.columns : picked
    }

    func storedRow(_ rowID: RowID) -> Row? {
        model.rows.row(withID: rowID)
    }

    func isRowDeleted(_ rowID: RowID) -> Bool {
        model.changeState?.isRowDeleted(rowID) == true
    }

    // MARK: - Rows

    func canDelete(_ scope: DataGridCommandScope) -> Bool {
        offers(.deleteRows) && !scope.selection.isEmpty && !rowIDs(scope).isEmpty
    }

    func deleteRows(_ scope: DataGridCommandScope) {
        guard offers(.deleteRows) else { return }
        let ids = rowIDs(scope)
        guard !ids.isEmpty else { return }
        model.actions?.gridDeleteRows(ids)
    }

    func deletedRowIDs(_ scope: DataGridCommandScope) -> [RowID] {
        rowIDs(scope).filter { isRowDeleted($0) }
    }

    // MARK: - Entered text

    // Read the way a typed cell is: a function the engine runs there is SQL, an emptied date, number or boolean is NULL.
    // Nil when the column holds neither the text nor NULL in its place.
    func enteredCell(_ text: String?, column: DataGridColumn) -> StagedCellEntry? {
        let rows = model.rows
        if let text,
           let databaseType = configuration.traits.databaseType,
           let typed = CellEntry.typed(
               text,
               columnType: rows.editingColumnType(at: column.dataIndex),
               databaseType: databaseType,
               writer: writerSupport
           ) {
            return typed
        }
        return rows.enteredValue(text, forColumn: column.dataIndex).map { (value: $0, isExpression: false) }
    }

    var writerSupport: CellWriterSupport {
        model.changeState?.cellWriterSupport ?? configuration.traits.cellWriterSupport
    }

    // One commit for every cell. The entry is read once per column; a column that refuses it keeps its cells and beeps.
    @discardableResult
    func applyEntry(
        to cells: [DataGridCommandCell],
        actionName: String,
        entry: (DataGridColumn) -> StagedCellEntry?
    ) -> Bool {
        guard !cells.isEmpty else { return false }
        var entries: [DataGridColumnID: StagedCellEntry?] = [:]
        var edits: [DataGridCellEdit] = []
        var refused = false
        for cell in cells where !isRowDeleted(cell.rowID) {
            let resolved: StagedCellEntry?
            if let cached = entries[cell.column.id] {
                resolved = cached
            } else {
                resolved = entry(cell.column)
                entries[cell.column.id] = .some(resolved)
            }
            guard let resolved else {
                refused = true
                continue
            }
            edits.append(DataGridCellEdit(
                rowID: cell.rowID,
                columnID: cell.column.id,
                value: .value(resolved.value, isExpression: resolved.isExpression)
            ))
        }
        if refused {
            NSSound.beep()
        }
        guard !edits.isEmpty else { return false }
        return model.commit(edits, actionName: actionName)
    }

    // What typing could edit: a read-only or server-owned column, a deleted row, a value not loaded and a binary value stay out.
    func typingCanEdit(_ cell: DataGridCommandCell) -> Bool {
        guard configuration.isEditable, model.isColumnWritable(cell.column), !isRowDeleted(cell.rowID),
              let row = storedRow(cell.rowID) else { return false }
        let dataIndex = cell.column.dataIndex
        guard dataIndex < row.values.count, row.unloadedByteCount(dataIndex) == nil else { return false }
        if cell.column.type?.isBlobType == true { return false }
        return row.values[dataIndex].asBytes == nil
    }
}

// Loads the values a page left on the server before a command reads them, then runs the command again once.
@MainActor
final class DataGridValueLoader {
    private var isRetrying = false

    func ensureLoaded(
        _ rowIDs: [RowID],
        columns: IndexSet?,
        in model: DataGridModel,
        retry: @escaping @MainActor () -> Void
    ) -> Bool {
        let rows = model.rows
        let pending = rowIDs.filter { rowID in
            guard let row = rows.row(withID: rowID) else { return false }
            return row.unloadedColumns.keys.contains { columns?.contains($0) ?? true }
        }
        guard !pending.isEmpty else { return true }
        // A retry that still finds a value missing would load forever.
        guard !isRetrying, let actions = model.actions, model.configuration.commands.contains(.loadUnloadedValues) else {
            NSSound.beep()
            return false
        }
        actions.gridLoadUnloadedValues(rowIDs: pending, columns: columns) { [weak self] loaded in
            guard loaded else {
                NSSound.beep()
                return
            }
            self?.isRetrying = true
            retry()
            self?.isRetrying = false
        }
        return false
    }
}
