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

        let buffer = rowDataStore.buffer(for: tab.id)
        let changes: [RowChange] = selectionState.indices.sorted().compactMap { rowIndex in
            guard rowIndex < buffer.rows.count else { return nil }
            let originalRow = buffer.rows[rowIndex]
            return RowChange(
                rowIndex: rowIndex,
                type: .update,
                cellChanges: editedFields.map { field in
                    CellChange(
                        rowIndex: rowIndex,
                        columnIndex: field.columnIndex,
                        columnName: field.columnName,
                        oldValue: originalRow[field.columnIndex],
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
