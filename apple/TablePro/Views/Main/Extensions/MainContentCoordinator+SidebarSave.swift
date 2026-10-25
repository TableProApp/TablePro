//
//  MainContentCoordinator+SidebarSave.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    func saveSidebarEdits(
        editState: MultiRowEditState
    ) async throws {
        let changes = sidebarEditChanges(editedFields: editState.getEditedFields())
        guard !changes.isEmpty else { return }
        // Held to its row counts as a grid save is, so a write that found no row fails instead of saving nothing.
        let steps = try changeManager.writeSteps(for: changes)
        guard !steps.isEmpty else { return }
        try await executeSidebarChanges(steps: steps)

        reloadActiveResult()
    }

    func sidebarEditStatements(
        editedFields: [InspectorFieldEdit]
    ) throws -> [ParameterizedStatement] {
        let changes = sidebarEditChanges(editedFields: editedFields)
        guard !changes.isEmpty else { return [] }
        return try changeManager.generateSQL(for: changes)
    }

    // Each row keeps its missing fields, so a removal writes as one and a typed value compares against an absent field.
    private func sidebarEditChanges(editedFields: [InspectorFieldEdit]) -> [RowChange] {
        guard let tab = tabManager.selectedTab,
            tab.tableContext.tableName != nil,
            let model = activeDataGridModel,
            !model.selection.isEmpty
        else {
            return []
        }

        guard !editedFields.isEmpty else { return [] }

        let tableRows = model.rows
        let writes = editedFields.compactMap { sidebarWrite(for: $0, in: tableRows) }
        guard !writes.isEmpty else { return [] }
        return model.selection.affectedRows.compactMap { displayRow -> RowChange? in
            guard let resolvedRow = model.row(at: displayRow) else { return nil }
            let originalRow = Array(resolvedRow.values)
            return RowChange(
                rowID: resolvedRow.id,
                type: .update,
                cellChanges: writes.map { write in
                    let field = write.field
                    let oldValue: PluginCellValue = field.columnIndex < originalRow.count
                        ? originalRow[field.columnIndex]
                        : .null
                    return CellChange(
                        columnIndex: field.columnIndex,
                        columnName: field.columnName,
                        oldValue: oldValue,
                        newValue: write.value,
                        oldIsAbsent: resolvedRow.isAbsent(field.columnIndex),
                        newIsAbsent: field.removesField,
                        newIsExpression: write.isExpression
                    )
                },
                originalRow: originalRow,
                absentColumns: resolvedRow.absentColumns
            )
        }
    }

    // Typed text is read for its column as the grid reads a cell (a date function stays a function); explicit NULL stays NULL.
    private func sidebarWrite(
        for field: InspectorFieldEdit,
        in tableRows: TableRows
    ) -> (field: InspectorFieldEdit, value: PluginCellValue, isExpression: Bool)? {
        guard !field.removesField, let text = field.newValue else { return (field, .null, false) }
        if field.isExpression { return (field, .text(text), true) }
        if let typed = CellEntry.typed(
            text,
            columnType: tableRows.editingColumnType(at: field.columnIndex),
            databaseType: changeManager.databaseType ?? connection.type,
            writer: changeManager.cellWriterSupport
        ) {
            return (field, typed.value, typed.isExpression)
        }
        return tableRows.enteredValue(text, forColumn: field.columnIndex).map { (field, $0, false) }
    }
}
