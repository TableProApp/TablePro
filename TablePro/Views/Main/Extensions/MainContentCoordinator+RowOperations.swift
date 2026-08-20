//
//  MainContentCoordinator+RowOperations.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    /// Whether the selected tab can take a new row.
    ///
    /// One definition, because the answer now drives two controls: the toolbar item that inserts the
    /// row and the data grid delegate that the Edit menu and the grid's own shortcut route through.
    var canAddRow: Bool {
        guard let tab = tabManager.selectedTab else { return false }
        guard tab.tableContext.tableName != nil else { return false }
        /// Only the data grid takes a row. `addNewRow()` resolves its target through
        /// `GridSelectionOwner`, which answers `.none` in Chart mode and `.schemaGrid` in Structure
        /// mode, so without this the command is either inert or adds a column under a row's name.
        guard tab.display.resultsViewMode == .data else { return false }
        return tab.tableContext.isEditable
            && !tab.tableContext.isView
            && !safeModeLevel.blocksAllWrites
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

    func undoInsertRow(at rowIndex: Int) {
        rowEditingCoordinator.undoInsertRow(at: rowIndex)
    }

    func handleUndoResult(_ result: UndoResult) {
        rowEditingCoordinator.handleUndoResult(result)
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
