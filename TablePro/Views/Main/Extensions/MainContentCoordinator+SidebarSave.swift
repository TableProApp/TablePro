//
//  MainContentCoordinator+SidebarSave.swift
//  TablePro
//
//  Sidebar save logic extracted from MainContentView.
//

import Foundation

extension MainContentCoordinator {
    // MARK: - Sidebar Save

    func saveSidebarEdits(
        editState: MultiRowEditState
    ) async throws {
        guard let tab = tabManager.selectedTab,
            !selectionState.indices.isEmpty,
            tab.tableContext.tableName != nil
        else {
            return
        }

        let editedFields = editState.getEditedFields()
        guard !editedFields.isEmpty else { return }

        let tableRows = tableRowsStore.tableRows(for: tab.id)
        let changes: [RowChange] = selectionState.indices.sorted().compactMap { rowIndex in
            guard rowIndex < tableRows.rows.count else { return nil }
            let originalRow = tableRows.rows[rowIndex].values
            return RowChange(
                rowIndex: rowIndex,
                type: .update,
                cellChanges: editedFields.map { field in
                    CellChange(
                        rowIndex: rowIndex,
                        columnIndex: field.columnIndex,
                        columnName: field.columnName,
                        oldValue: field.columnIndex < originalRow.count ? originalRow[field.columnIndex] : nil,
                        newValue: field.newValue
                    )
                },
                originalRow: originalRow
            )
        }

        // Route through the unified statement generation pipeline
        let statements = try changeManager.generateSQL(for: changes)
        guard !statements.isEmpty else { return }
        try await executeSidebarChanges(statements: statements)

        runQuery()
    }
}
