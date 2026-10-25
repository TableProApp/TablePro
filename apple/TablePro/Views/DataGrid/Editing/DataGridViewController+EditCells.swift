//
//  DataGridViewController+EditCells.swift
//  TablePro
//

import AppKit
import TableProPluginKit

extension DataGridViewController {
    // MARK: - Cells

    func editCell(at coord: GridCoord) -> DataGridEditCell? {
        guard let row = model.row(at: coord.row), let column = model.columns.column(at: coord.displayColumn) else { return nil }
        return DataGridEditCell(coord: coord, row: row, column: column)
    }

    func editCell(for target: DataGridEditTarget) -> DataGridEditCell? {
        guard let row = model.displayIndex(of: target.rowID),
              let column = model.columns.displayPosition(of: target.columnID) else { return nil }
        return editCell(at: GridCoord(row: row, displayColumn: column))
    }

    // A replaced result reuses RowIDs for other records.
    func editCell(for held: DataGridHeldRow) -> DataGridEditCell? {
        guard let cell = editCell(for: held.target), cell.row.values == held.values else { return nil }
        return cell
    }

    func heldRow(_ cell: DataGridEditCell) -> DataGridHeldRow {
        DataGridHeldRow(target: cell.target, values: cell.row.values)
    }

    func isRowDeleted(_ rowID: RowID) -> Bool {
        model.changeState?.isRowDeleted(rowID) == true
    }

    func textEditableValue(of cell: DataGridEditCell) -> String? {
        guard model.configuration.isEditable,
              !isRowDeleted(cell.row.id),
              model.isColumnWritable(cell.column),
              !cell.isUnloaded,
              cell.column.type?.isBlobType != true,
              cell.value.asBytes == nil else { return nil }
        return cell.value.asText ?? ""
    }

    func cellContext(for cell: DataGridEditCell) -> CellContext {
        let name = cell.column.name
        let rows = model.rows
        let value = cell.value
        // A column the owner locked is not read-only content: it refuses with a beep instead (#2726).
        let serverOwned = model.configuration.traits.immutableColumns.contains(name)
            || model.changeState?.generatedColumns.contains(name) == true
        return CellContext(
            columnType: cell.column.type,
            value: value.asText,
            isTableEditable: model.configuration.isEditable,
            isRowDeleted: isRowDeleted(cell.row.id),
            isImmutableColumn: serverOwned,
            isBinaryValue: value.asBytes != nil,
            isForeignKey: rows.columnForeignKeys[name] != nil,
            displayFormatOverride: model.displayFormat(for: cell.column),
            detectedContent: CellValueContentDetector.detect(value)
        )
    }

    // A grid that refuses a keystroke in silence reads as broken (#2726).
    func refuseEdit(of column: DataGridColumn) {
        let configuration = model.configuration
        if configuration.lockedColumns.contains(column.name) || (!configuration.isEditable && configuration.editRefusalMessage != nil) {
            NSSound.beep()
        }
    }

    // MARK: - Geometry

    // A frozen column's home in the main table lies under the frozen pane.
    func editingPane(forDisplayColumn displayColumn: Int) -> DataGridPane {
        if !frozen.scrollView.isHidden, frozen.tableIndex(forDisplayPosition: displayColumn, columns: model.columns) != nil {
            return frozen
        }
        return main
    }

    func cellFrame(of coord: GridCoord) -> (pane: DataGridPane, tableIndex: Int, rect: NSRect)? {
        let pane = editingPane(forDisplayColumn: coord.displayColumn)
        let table = pane.tableView
        guard coord.row >= 0, coord.row < table.numberOfRows,
              let index = pane.tableIndex(forDisplayPosition: coord.displayColumn, columns: model.columns),
              index < table.numberOfColumns else { return nil }
        return (pane, index, table.frameOfCell(atColumn: index, row: coord.row))
    }

    // MARK: - Commit

    @discardableResult
    static func commitEnteredText(_ text: String?, to target: DataGridEditTarget, in model: DataGridModel?) -> Bool {
        guard let model else { return false }
        if refusesEntry(text, for: target, in: model) {
            NSSound.beep()
            return false
        }
        model.commit(
            [DataGridCellEdit(rowID: target.rowID, columnID: target.columnID, value: .enteredText(text))],
            actionName: String(localized: "Edit Cell")
        )
        return true
    }

    @discardableResult
    static func commitValue(_ value: PluginCellValue, to target: DataGridEditTarget, in model: DataGridModel?) -> Bool {
        guard let model else { return false }
        return model.commit(
            [DataGridCellEdit(rowID: target.rowID, columnID: target.columnID, value: .value(value, isExpression: false))],
            actionName: String(localized: "Edit Cell")
        )
    }

    private static func refusesEntry(_ text: String?, for target: DataGridEditTarget, in model: DataGridModel) -> Bool {
        let rows = model.rows
        let ids = DataGridColumnSet.columnIDs(for: rows.columns)
        guard let dataIndex = ids.firstIndex(of: target.columnID) else { return false }
        let traits = model.configuration.traits
        if let text, let databaseType = traits.databaseType,
           CellEntry.typed(
               text,
               columnType: rows.editingColumnType(at: dataIndex),
               databaseType: databaseType,
               writer: traits.cellWriterSupport
           ) != nil {
            return false
        }
        return rows.enteredValue(text, forColumn: dataIndex) == nil
    }

    // MARK: - Unloaded values

    // A value left on the server reads NULL until loaded (#3758); the retry finds the record by identity.
    func loadsUnloadedValue(
        of cell: DataGridEditCell,
        then retry: @escaping @MainActor (DataGridViewController) -> Void
    ) -> Bool {
        guard cell.isUnloaded else { return true }
        guard let actions = model.actions else {
            NSSound.beep()
            return false
        }
        let target = cell.target
        actions.gridLoadUnloadedValues(rowIDs: [target.rowID], columns: IndexSet(integer: cell.column.dataIndex)) { [weak self] loaded in
            guard let self else { return }
            guard loaded, let current = self.editCell(for: target), !current.isUnloaded else {
                NSSound.beep()
                return
            }
            retry(self)
        }
        return false
    }

    // MARK: - Opening

    func openEditor(for target: DataGridEditTarget) {
        guard let cell = editCell(for: target) else { return }
        openEditor(at: cell.coord)
    }

    func openEditor(at coord: GridCoord) {
        guard let cell = editCell(at: coord) else { return }
        let target = cell.target
        guard loadsUnloadedValue(of: cell, then: { $0.openEditor(for: target) }) else { return }
        let mode = CellInteractionResolver().resolve(cellContext(for: cell))
        switch mode {
        case .blocked:
            return
        case .viewText(let value):
            showTextPopover(for: cell, text: value, isEditable: false)
        case .viewJson:
            showJSONViewer(for: cell)
        case .viewBlob:
            showBlobPopover(for: cell, isEditable: false)
        case .viewPhpSerialized:
            showPhpViewer(for: cell)
        case .viewBinaryValue(let format):
            showBinaryValueViewer(for: cell, format: format)
        case .viewVector, .editVector:
            showVectorPopover(for: cell, isEditable: mode == .editVector && textEditableValue(of: cell) != nil)
        case .viewSvg, .editSvg:
            showSvgPopover(for: cell, isEditable: mode == .editSvg && textEditableValue(of: cell) != nil)
        case .editInline, .editText:
            beginTextEditing(cell)
        case .editForeignKey:
            showForeignKeyPicker(for: cell)
        case .editJson:
            showJSONEditor(for: cell)
        case .editBlob:
            showBlobPopover(for: cell, isEditable: true)
        }
    }

    @discardableResult
    func beginTextEditing(_ cell: DataGridEditCell) -> Bool {
        guard let original = textEditableValue(of: cell) else {
            refuseEdit(of: cell.column)
            return false
        }
        if CellInteractionResolver.editsInPopover(original) {
            return beginTextPopoverEditing(cell, text: original, original: original, selection: nil)
        }
        return beginFieldEditing(cell, text: original, original: original, selection: nil, reveals: true)
    }

    func beginTextEditing(for target: DataGridEditTarget) {
        guard let cell = editCell(for: target) else { return }
        beginTextEditing(cell)
    }
}
