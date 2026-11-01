//
//  MainContentCoordinator+RowOperations.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    // One definition for both the toolbar item and the data grid's empty-space Add Row item.
    var canAddRow: Bool {
        guard canEditActiveResult(.insert), let tab = tabManager.selectedTab else { return false }
        guard tab.tableContext.tableName != nil else { return false }
        // `GridSelectionOwner` answers `.none` in Chart and `.schemaGrid` in Structure, so elsewhere Add Row is inert or adds a column.
        guard tab.display.resultsViewMode == .data else { return false }
        // A new row pre-fills server-filled columns from the schema, so wait for it rather than stage NULL into an identity column.
        return tabSessionRegistry.tableRows(for: tab.id).hasAuthoritativeSchema
    }

    func addNewRow() {
        rowEditingCoordinator.addNewRow()
    }

    func deleteRows(_ rowIDs: [RowID]) {
        rowEditingCoordinator.deleteRows(rowIDs)
    }

    func undoRowDeletions(_ rowIDs: [RowID]) {
        rowEditingCoordinator.undoRowDeletions(rowIDs)
    }

    func duplicateRow(_ rowID: RowID) {
        rowEditingCoordinator.duplicateRow(rowID)
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

    func copyRowsToClipboard(_ rowIDs: [RowID], includeHeaders: Bool = false) {
        rowEditingCoordinator.copyRowsToClipboard(rowIDs, includeHeaders: includeHeaders)
    }

    func copyRowsAsJson(_ rowIDs: [RowID]) {
        rowEditingCoordinator.copyRowsAsJson(rowIDs)
    }

    func pasteRows() {
        rowEditingCoordinator.pasteRows()
    }
}
