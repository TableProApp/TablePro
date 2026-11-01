//
//  RowEditingCoordinator.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

@MainActor
final class RowEditingCoordinator: ObservableObject {
    unowned let parent: MainContentCoordinator

    // Nothing clears the pending changes until the write returns, so a second Cmd+S in the round trip would commit twice.
    private(set) var isSaveInFlight = false

    init(parent: MainContentCoordinator) {
        self.parent = parent
    }

    func beginSaveInFlight() -> Bool {
        guard !isSaveInFlight else { return false }
        isSaveInFlight = true
        return true
    }

    func endSaveInFlight() {
        isSaveInFlight = false
    }

    // A row command selects the row it made. The JSON view reads the selection as "show only these rows".
    private var selectionPointsTheGrid: Bool {
        parent.tabManager.selectedTab?.display.resultsViewMode == .data
    }

    // MARK: - Row Operations

    func addNewRow() {
        guard parent.canEditActiveResult(.insert),
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              tab.tableContext.tableName != nil else { return }

        let tabId = tab.id
        // Pre-filled from the schema's account of which columns the server owns; without it an identity gets NULL.
        let tableRows = parent.tabSessionRegistry.tableRows(for: tabId)
        guard tableRows.hasAuthoritativeSchema else { return }

        parent.commitActiveGridEdit()

        let uuidKeys = uuidKeyForms(in: tableRows, tab: tab)
        var addResult: RowOperationsManager.AddNewRowResult?
        parent.mutateActiveTableRows(for: tabId) { rows in
            let result = parent.rowOperationsManager.addNewRow(tableRows: &rows, uuidKeyForms: uuidKeys)
            addResult = result
            return result?.delta ?? .none
        }

        guard let result = addResult else { return }

        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
        selectAndEditInsertedRow(result.rowID, tabId: tabId, skipping: result.prefilledColumns)
    }

    func deleteRows(_ rowIDs: [RowID]) {
        guard parent.canEditActiveResult(.delete),
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              !rowIDs.isEmpty else { return }

        let tabId = tab.id
        let model = parent.gridModel(forTab: tabId)
        let displayIndices = Set(rowIDs.compactMap { model.displayIndex(of: $0) })
        let displayCount = model.rowCount

        var deleteResult = RowOperationsManager.DeleteRowsResult(
            nextRowToSelect: -1,
            physicallyRemovedIndices: [],
            delta: .none
        )
        parent.mutateActiveTableRows(for: tabId) { rows in
            let result = parent.rowOperationsManager.deleteRows(
                rowIDs,
                selectedDisplayIndices: displayIndices,
                displayCount: displayCount,
                tableRows: &rows
            )
            deleteResult = result
            return result.delta
        }

        guard deleteResult.stagedRowCount > 0 else { return }

        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
        model.repaintRows(rowIDs)

        guard selectionPointsTheGrid else { return }
        if let next = model.rowID(at: deleteResult.nextRowToSelect) {
            model.selectRows([next])
        } else {
            model.clearSelection()
        }
    }

    func undoRowDeletions(_ rowIDs: [RowID]) {
        guard parent.canEditActiveResult(.delete), let tabId = parent.tabManager.selectedTabId else { return }
        let deleted = rowIDs.filter { parent.changeManager.isRowDeleted($0) }
        guard !deleted.isEmpty else { return }
        for rowID in deleted {
            parent.changeManager.undoRowDeletion(rowID: rowID)
        }
        parent.existingGridModel(forTab: tabId)?.repaintRows(deleted)
    }

    func duplicateRow(_ rowID: RowID) {
        guard parent.canEditActiveResult(.insert),
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              tab.tableContext.tableName != nil else { return }

        let tabId = tab.id
        let tableRows = parent.tabSessionRegistry.tableRows(for: tabId)
        guard tableRows.hasAuthoritativeSchema,
              let storageIndex = tableRows.index(of: rowID) else { return }
        guard parent.unloadedValuesAreLoaded(rowIDs: [rowID], retry: { [weak self] in
            self?.duplicateRow(rowID)
        }) else { return }

        parent.commitActiveGridEdit()

        let uuidKeys = uuidKeyForms(in: tableRows, tab: tab)
        var dupResult: RowOperationsManager.AddNewRowResult?
        parent.mutateActiveTableRows(for: tabId) { rows in
            let result = parent.rowOperationsManager.duplicateRow(
                sourceRowIndex: storageIndex,
                tableRows: &rows,
                uuidKeyForms: uuidKeys
            )
            dupResult = result
            return result?.delta ?? .none
        }

        guard let result = dupResult else { return }

        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
        selectAndEditInsertedRow(result.rowID, tabId: tabId, skipping: result.prefilledColumns)
    }

    // The caret skips a key the row was given a fresh UUID for, so the first keystroke does not replace it.
    private func selectAndEditInsertedRow(_ rowID: RowID, tabId: UUID, skipping prefilled: Set<Int>) {
        guard selectionPointsTheGrid,
              let model = parent.existingGridModel(forTab: tabId),
              let displayRow = model.displayIndex(of: rowID) else { return }
        let row = model.rows.row(withID: rowID)
        let typable = model.columns.columns.filter { model.isColumnWritable($0) && Self.takesTypedText($0, in: row) }
        // Column 0 is where the row starts, not always where it can be typed into: the server may own it.
        guard let column = typable.first(where: { !prefilled.contains($0.dataIndex) }) ?? typable.first ?? model.columns.columns.first,
              let displayColumn = model.columns.displayPosition(of: column.id) else {
            model.selectRows([rowID])
            model.reveal(rowID: rowID)
            return
        }
        model.selectCell(GridCoord(row: displayRow, displayColumn: displayColumn))
        model.reveal(rowID: rowID, columnID: column.id)
        if typable.contains(where: { $0.id == column.id }) {
            model.beginEditing(rowID: rowID, columnID: column.id)
        }
    }

    // The grid's text editor refuses bytes, so a BLOB column would take the caret and open nothing.
    private static func takesTypedText(_ column: DataGridColumn, in row: Row?) -> Bool {
        column.type?.isBlobType != true && row?[column.dataIndex].asBytes == nil
    }

    private func uuidKeyForms(in tableRows: TableRows, tab: QueryTab) -> [Int: UUIDCellForm] {
        let changeManager = parent.changeManager
        return Self.uuidKeyForms(
            in: tableRows,
            primaryKeyColumns: changeManager.primaryKeyColumns,
            displayFormats: parent.displayFormats(for: tab),
            databaseType: parent.connection.type,
            writer: changeManager.cellWriterSupport,
            isColumnWritable: { changeManager.isColumnWritable($0) }
        )
    }

    // A UUID key the server does not fill; asked of SetValueOptions, so it is skipped wherever Generate UUID is hidden.
    static func uuidKeyForms(
        in tableRows: TableRows,
        primaryKeyColumns: [String],
        displayFormats: [ValueDisplayFormat?],
        databaseType: DatabaseType,
        writer: CellWriterSupport,
        isColumnWritable: (String) -> Bool
    ) -> [Int: UUIDCellForm] {
        let keys = Set(primaryKeyColumns)
        guard writer.acceptsUUIDText, !keys.isEmpty else { return [:] }
        var forms: [Int: UUIDCellForm] = [:]
        for (index, column) in tableRows.columns.enumerated() where keys.contains(column) {
            guard !tableRows.serverAssignsValue(forColumn: column),
                  !tableRows.generatedColumns.contains(column) else { continue }
            let context = SetValueContext(
                columnType: tableRows.editingColumnType(at: index),
                isNullable: tableRows.columnNullable[column] ?? true,
                serverAssignsValue: false,
                isForeignKey: tableRows.columnForeignKeys[column] != nil,
                isWritable: isColumnWritable(column),
                displayFormat: displayFormats[safe: index] ?? nil,
                sampleText: sampleText(atColumn: index, in: tableRows),
                declaredType: tableRows.declaredType(at: index),
                databaseType: databaseType,
                rowIsInserted: true,
                writer: writer
            )
            if let form = SetValueOptions.uuidForm(for: context) {
                forms[index] = form
            }
        }
        return forms
    }

    private static func sampleText(atColumn index: Int, in tableRows: TableRows) -> String? {
        for row in tableRows.rows where row.values.indices.contains(index) {
            if case .text(let text) = row.values[index], text != "__DEFAULT__" { return text }
        }
        return nil
    }

    // The next undo step then lands after the typed run, not inside it.
    func endInspectorEditRun() {
        parent.changeManager.endCoalescedUndoRun()
    }

    // By RowID, each row with its own oldValue: a shared one is wrong when a multi-row selection disagrees on the field.
    func stageInspectorFieldEdit(
        columnIndex: Int,
        value: PluginCellValue,
        rowIDs: [RowID],
        continuity: FieldEditContinuity,
        isExpression: Bool = false
    ) {
        stageInspectorEdits(
            valuesByRow: Dictionary(rowIDs.map { ($0, value) }, uniquingKeysWith: { first, _ in first }),
            columnIndex: columnIndex,
            continuity: continuity,
            expressionRowIDs: isExpression ? Set(rowIDs) : []
        )
    }

    // One undo step for all rows.
    func stageInspectorFieldValues(columnIndex: Int, valuesByRow: [RowID: PluginCellValue]) {
        stageInspectorEdits(valuesByRow: valuesByRow, columnIndex: columnIndex, continuity: .discrete)
    }

    // Disagreeing rows get their own values back; absentRowIDs go back to missing, expressionRowIDs back to SQL.
    func revertInspectorFieldEdit(
        columnIndex: Int,
        valuesByRow: [RowID: PluginCellValue],
        absentRowIDs: Set<RowID> = [],
        expressionRowIDs: Set<RowID> = []
    ) {
        stageInspectorEdits(
            valuesByRow: valuesByRow,
            columnIndex: columnIndex,
            continuity: .typing,
            removingFieldFrom: absentRowIDs,
            expressionRowIDs: expressionRowIDs
        )
    }

    // For an engine that tells a missing field from NULL.
    func stageInspectorFieldRemoval(columnIndex: Int, rowIDs: [RowID]) {
        guard parent.changeManager.supportsFieldRemoval else { return }
        stageInspectorEdits(
            valuesByRow: Dictionary(rowIDs.map { ($0, PluginCellValue.null) }, uniquingKeysWith: { first, _ in first }),
            columnIndex: columnIndex,
            continuity: .discrete,
            removingFieldFrom: Set(rowIDs)
        )
    }

    private func stageInspectorEdits(
        valuesByRow: [RowID: PluginCellValue],
        columnIndex: Int,
        continuity: FieldEditContinuity,
        removingFieldFrom removedRowIDs: Set<RowID> = [],
        expressionRowIDs: Set<RowID> = []
    ) {
        if continuity == .discrete {
            endInspectorEditRun()
        }
        guard let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex, !valuesByRow.isEmpty else { return }
        let tabId = tab.id
        let tableRows = parent.tabSessionRegistry.tableRows(for: tabId)
        guard tableRows.columns.indices.contains(columnIndex) else { return }
        let columnName = tableRows.columns[columnIndex]
        // Checked before touching rows: a server-owned column is refused later, so the grid would show a value nothing writes.
        guard parent.changeManager.isColumnWritable(columnName) else { return }

        var edits: [(row: Int, column: Int, value: PluginCellValue)] = []
        var removedCells: Set<CellPosition> = []
        for (rowID, value) in valuesByRow {
            guard let storageRow = tableRows.index(of: rowID) else { continue }
            let row = tableRows.rows[storageRow]
            guard row.unloadedByteCount(columnIndex) == nil else { continue }
            let values = Array(row.values)
            let removesField = removedRowIDs.contains(rowID) && parent.changeManager.supportsFieldRemoval
            let absence = FieldAbsence(
                wasAbsent: row.isAbsent(columnIndex), isAbsent: removesField, originalRow: row.absentColumns
            )
            let isExpression = expressionRowIDs.contains(rowID) && !removesField
            let wasExpression = parent.changeManager.isExpression(rowID: rowID, columnIndex: columnIndex)
            guard values.indices.contains(columnIndex),
                  values[columnIndex] != value || absence.wasAbsent != absence.isAbsent
                    || wasExpression != isExpression else { continue }
            if continuity == .typing {
                parent.changeManager.recordTypedCellChange(
                    rowID: rowID,
                    columnIndex: columnIndex,
                    columnName: columnName,
                    oldValue: values[columnIndex],
                    newValue: value,
                    originalRow: values,
                    absence: absence,
                    isExpression: isExpression
                )
            } else {
                parent.changeManager.recordCellChange(
                    rowID: rowID,
                    columnIndex: columnIndex,
                    columnName: columnName,
                    oldValue: values[columnIndex],
                    newValue: value,
                    originalRow: values,
                    absence: absence,
                    isExpression: isExpression
                )
            }
            edits.append((row: storageRow, column: columnIndex, value: value))
            if removesField {
                removedCells.insert(CellPosition(row: storageRow, column: columnIndex))
            }
        }
        guard !edits.isEmpty else { return }

        parent.mutateActiveTableRows(for: tabId) { rows in rows.editMany(edits, absentCells: removedCells) }
        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
        parent.inspectorRowContentChanged.send()
    }

    // One user command, one undo step named for it; the buffer write reaches the grid as one delta.
    func commitGridEdits(_ resolved: [DataGridResolvedEdit], actionName: String, tabId: UUID) -> Bool {
        let changeManager = parent.changeManager
        let tableRows = parent.tabSessionRegistry.tableRows(for: tabId)
        var edits: [(row: Int, column: Int, value: PluginCellValue)] = []
        var removedCells: Set<CellPosition> = []
        for edit in resolved {
            guard let storageRow = tableRows.index(of: edit.rowID) else { continue }
            changeManager.recordCellChange(
                rowID: edit.rowID,
                columnIndex: edit.dataIndex,
                columnName: edit.columnName,
                oldValue: edit.oldValue,
                newValue: edit.newValue,
                originalRow: edit.originalRow,
                absence: edit.absence,
                isExpression: edit.isExpression
            )
            edits.append((row: storageRow, column: edit.dataIndex, value: edit.newValue))
            if edit.absence.isAbsent {
                removedCells.insert(CellPosition(row: storageRow, column: edit.dataIndex))
            }
        }
        guard !edits.isEmpty else { return false }
        changeManager.undoManagerProvider?()?.setActionName(actionName)
        parent.mutateActiveTableRows(for: tabId) { rows in rows.editMany(edits, absentCells: removedCells) }
        parent.tabManager.mutate(tabId: tabId) { $0.hasUserInteraction = true }
        return true
    }

    func handleUndoResult(_ result: UndoResult) {
        guard let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex else { return }

        let tabId = tab.id

        var application = RowOperationsManager.UndoApplicationResult(clearsSelection: false, delta: .none)
        parent.mutateActiveTableRows(for: tabId) { rows in
            let applied = parent.rowOperationsManager.applyUndoResult(result, tableRows: &rows)
            application = applied
            return applied.delta
        }

        let model = parent.existingGridModel(forTab: tabId)
        if application.clearsSelection {
            model?.clearSelection()
        }

        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
        model?.repaintAllRows()
        // The inspector reads its fields from the rows this rewrote, and nothing else it watches moves on an undo.
        parent.gridDisplayRevision &+= 1
    }

    func copyRowsToClipboard(_ rowIDs: [RowID], includeHeaders: Bool = false) {
        guard let (tab, _) = parent.tabManager.selectedTabAndIndex, !rowIDs.isEmpty else { return }
        guard parent.unloadedValuesAreLoaded(rowIDs: rowIDs, retry: { [weak self] in
            self?.copyRowsToClipboard(rowIDs, includeHeaders: includeHeaders)
        }) else { return }
        parent.rowOperationsManager.copyRowsToClipboard(
            rowIDs,
            tableRows: parent.tabSessionRegistry.tableRows(for: tab.id),
            includeHeaders: includeHeaders,
            visibleColumnIndices: presentedColumnIndices(tabId: tab.id)
        )
    }

    func copyRowsAsJson(_ rowIDs: [RowID]) {
        guard let (tab, _) = parent.tabManager.selectedTabAndIndex, !rowIDs.isEmpty else { return }
        guard parent.unloadedValuesAreLoaded(rowIDs: rowIDs, retry: { [weak self] in
            self?.copyRowsAsJson(rowIDs)
        }) else { return }
        let model = parent.gridModel(forTab: tab.id)
        let output = ResultJsonSerializer.serialize(
            tableRows: parent.tabSessionRegistry.tableRows(for: tab.id),
            displayIDs: model.displayedRowIDs,
            selectedDisplayIndices: Set(rowIDs.compactMap { model.displayIndex(of: $0) }),
            columns: VisibleColumnProjection(indices: presentedColumnIndices(tabId: tab.id))
        )
        guard output.rowCount > 0 else { return }
        ClipboardService.shared.writeText(output.json)
    }

    // The columns the grid presents, in its order: hidden ones go, moved ones follow.
    private func presentedColumnIndices(tabId: UUID) -> [Int] {
        parent.gridModel(forTab: tabId).columns.columns.map(\.dataIndex)
    }

    func pasteRows() {
        guard parent.canEditActiveResult(.insert),
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              tab.tabType == .table else { return }

        let tabId = tab.id
        // Pasted rows hand the server-owned columns back to it, which only the schema names, so this waits for it.
        let tableRows = parent.tabSessionRegistry.tableRows(for: tabId)
        guard tableRows.hasAuthoritativeSchema else { return }
        let columns = tableRows.columns
        let uuidKeys = uuidKeyForms(in: tableRows, tab: tab)

        var pasteResult = RowOperationsManager.PasteRowsResult(pastedRows: [], delta: .none)
        parent.mutateActiveTableRows(for: tabId) { rows in
            let result = parent.rowOperationsManager.pasteRowsFromClipboard(
                columns: columns,
                primaryKeyColumns: parent.changeManager.primaryKeyColumns,
                tableRows: &rows,
                uuidKeyForms: uuidKeys
            )
            pasteResult = result
            return result.delta
        }

        guard !pasteResult.pastedRows.isEmpty else { return }

        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
        if selectionPointsTheGrid {
            parent.existingGridModel(forTab: tabId)?.selectRows(pasteResult.pastedRows.map(\.rowID))
        }
    }
}
