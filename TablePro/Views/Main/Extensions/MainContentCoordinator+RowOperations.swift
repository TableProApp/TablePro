//
//  MainContentCoordinator+RowOperations.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    /// Whether the selected tab can take a new row.
    ///
    /// One definition, because the answer drives two controls: the toolbar item that inserts the row
    /// and the **Add Row** item on the data grid's empty-space menu.
    var canAddRow: Bool {
        guard canEditActiveResult, let tab = tabManager.selectedTab else { return false }
        guard tab.tableContext.tableName != nil else { return false }
        /// Only the data grid takes a row. `addNewRow()` resolves its target through
        /// `GridSelectionOwner`, which answers `.none` in Chart mode and `.schemaGrid` in Structure
        /// mode, so without this the command is either inert or adds a column under a row's name.
        guard tab.display.resultsViewMode == .data else { return false }
        /// A new row is pre-filled from the schema's account of which columns the server fills in,
        /// so the command waits for that account rather than staging NULL into an identity column.
        return tabSessionRegistry.tableRows(for: tab.id).hasAuthoritativeSchema
    }

    func addNewRow() {
        rowEditingCoordinator.addNewRow()
    }

    func deleteSelectedRows(indices: Set<Int>) {
        rowEditingCoordinator.deleteSelectedRows(indices: indices)
    }

    func duplicateSelectedRow(index: Int) {
        rowEditingCoordinator.duplicateSelectedRow(index: index)
    }

    func handleUndoResult(_ result: UndoResult) {
        rowEditingCoordinator.handleUndoResult(result)
    }

    func stageInspectorFieldEdit(
        columnIndex: Int,
        value: PluginCellValue,
        rowIDs: [RowID],
        continuity: FieldEditContinuity
    ) {
        rowEditingCoordinator.stageInspectorFieldEdit(
            columnIndex: columnIndex,
            value: value,
            rowIDs: rowIDs,
            continuity: continuity
        )
    }

    func endInspectorEditRun() {
        rowEditingCoordinator.endInspectorEditRun()
    }

    func revertInspectorFieldEdit(
        columnIndex: Int,
        valuesByRow: [RowID: PluginCellValue],
        absentRowIDs: Set<RowID> = []
    ) {
        rowEditingCoordinator.revertInspectorFieldEdit(
            columnIndex: columnIndex, valuesByRow: valuesByRow, absentRowIDs: absentRowIDs
        )
    }

    func stageInspectorFieldRemoval(columnIndex: Int, rowIDs: [RowID]) {
        rowEditingCoordinator.stageInspectorFieldRemoval(columnIndex: columnIndex, rowIDs: rowIDs)
    }

    func copySelectedRowsToClipboard(indices: Set<Int>) {
        rowEditingCoordinator.copySelectedRowsToClipboard(indices: indices)
    }

    func copySelectedRowsWithHeaders(indices: Set<Int>) {
        rowEditingCoordinator.copySelectedRowsWithHeaders(indices: indices)
    }

    func copySelectedRowsAsJson(indices: Set<Int>) {
        rowEditingCoordinator.copySelectedRowsAsJson(indices: indices)
    }

    func pasteRows() {
        rowEditingCoordinator.pasteRows()
    }

    func updateCellInTab(rowIndex: Int, columnIndex: Int, value: String?) {
        rowEditingCoordinator.updateCellInTab(
            rowIndex: rowIndex,
            columnIndex: columnIndex,
            value: PluginCellValue.fromOptional(value)
        )
    }
}
