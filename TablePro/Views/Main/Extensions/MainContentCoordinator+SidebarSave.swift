//
//  MainContentCoordinator+SidebarSave.swift
//  TablePro
//
//  Sidebar save logic extracted from MainContentView.
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    // MARK: - Sidebar Save

    func saveSidebarEdits(
        editState: MultiRowEditState
    ) async throws {
        guard let tab = tabManager.selectedTab,
            !selectionState.indices.isEmpty,
            tab.tableContext.tableName != nil,
            GridSelectionOwner.resolve(
                tabType: tab.tabType,
                resultsViewMode: tab.display.resultsViewMode
            ) == .dataGrid
        else {
            return
        }

        let editedFields = editState.getEditedFields()
        guard !editedFields.isEmpty else { return }

        let tableRows = tabSessionRegistry.tableRows(for: tab.id)
        let displayIDs = activeGridDisplayIDs
        let changes: [RowChange] = selectionState.indices.sorted().compactMap { rowIndex -> RowChange? in
            guard let resolvedRow = DisplayRowMapping.row(
                forDisplay: rowIndex,
                displayIDs: displayIDs,
                in: tableRows
            ) else { return nil }
            let originalRow = Array(resolvedRow.values)
            return RowChange(
                rowIndex: rowIndex,
                type: .update,
                cellChanges: editedFields.map { field in
                    let oldValue: PluginCellValue = field.columnIndex < originalRow.count
                        ? originalRow[field.columnIndex]
                        : .null
                    return CellChange(
                        columnIndex: field.columnIndex,
                        columnName: field.columnName,
                        oldValue: oldValue,
                        newValue: PluginCellValue.fromOptional(field.newValue)
                    )
                },
                originalRow: originalRow
            )
        }

        let statements = try changeManager.generateSQL(for: changes)
        guard !statements.isEmpty else { return }
        try await executeSidebarChanges(statements: statements)

        runQuery()
    }
}
