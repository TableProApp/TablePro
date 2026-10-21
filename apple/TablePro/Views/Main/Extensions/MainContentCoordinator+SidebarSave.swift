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

    // Each row keeps which fields it has none of, so a removal is written as one and a value typed into a missing
    // field is compared against a field that is not there.
    private func sidebarEditChanges(editedFields: [InspectorFieldEdit]) -> [RowChange] {
        guard let tab = tabManager.selectedTab,
            !selectionState.indices.isEmpty,
            tab.tableContext.tableName != nil,
            GridSelectionOwner.resolve(
                tabType: tab.tabType,
                resultsViewMode: tab.display.resultsViewMode
            ) == .dataGrid
        else {
            return []
        }

        guard !editedFields.isEmpty else { return [] }

        let tableRows = tabSessionRegistry.tableRows(for: tab.id)
        let writes = editedFields.compactMap { sidebarWrite(for: $0, in: tableRows) }
        guard !writes.isEmpty else { return [] }
        let displayIDs = activeGridDisplayIDs
        return selectionState.indices.sorted().compactMap { rowIndex -> RowChange? in
            guard let resolvedRow = DisplayRowMapping.row(
                forDisplay: rowIndex,
                displayIDs: displayIDs,
                in: tableRows
            ) else { return nil }
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

    /// Typed text is read for its column, as the grid reads a cell: a function name on a date column is the
    /// function, and text a NOT NULL column can hold neither as itself nor as NULL writes nothing. An explicit
    /// NULL stays NULL, and SQL picked from the menu is already the vocabulary's spelling.
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
