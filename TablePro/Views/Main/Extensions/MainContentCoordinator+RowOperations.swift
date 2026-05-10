//
//  MainContentCoordinator+RowOperations.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
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
