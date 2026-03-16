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
        selectedRowIndices: Set<Int>,
        editState: MultiRowEditState
    ) async throws {
        guard let tab = tabManager.selectedTab,
            !selectedRowIndices.isEmpty,
            tab.tableName != nil
        else {
            return
        }

        let editedFields = editState.getEditedFields()
        guard !editedFields.isEmpty else { return }

        // Build RowChange array from sidebar edits
        let changes: [RowChange] = selectedRowIndices.sorted().compactMap { rowIndex in
            guard rowIndex < tab.resultRows.count else { return nil }
            let originalRow = tab.resultRows[rowIndex].values
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
