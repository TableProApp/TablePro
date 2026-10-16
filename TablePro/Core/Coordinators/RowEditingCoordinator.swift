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

    /// A save is between assembling its statements and hearing back.
    ///
    /// Nothing clears the pending changes until the write returns, so a second Cmd+S inside the
    /// round trip finds them still there, assembles the same statements again and commits them
    /// twice. Over a slow link that is easy to do by accident.
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

    /// A row command selects the row it just made so the grid can highlight it and scroll to it.
    /// No other mode has a grid to point at, and the JSON view reads the same selection as "show
    /// only these rows", so writing it there collapses the document to the one new row.
    private var selectionPointsTheGrid: Bool {
        parent.tabManager.selectedTab?.display.resultsViewMode == .data
    }

    // MARK: - Row Operations

    func addNewRow() {
        guard parent.canEditActiveResult,
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              tab.tableContext.tableName != nil else { return }

        let tabId = tab.id
        /// A new row is pre-filled from the schema's account of which columns the server owns, so
        /// staging one before that account exists writes NULL into an identity column.
        let tableRows = parent.tabSessionRegistry.tableRows(for: tabId)
        guard tableRows.hasAuthoritativeSchema else { return }

        parent.dataTabDelegate?.tableViewCoordinator?.commitActiveCellEdit()

        let uuidKeys = uuidKeyForms(in: tableRows, tab: tab)
        var addResult: RowOperationsManager.AddNewRowResult?
        parent.mutateActiveTableRows(for: tabId) { rows in
            let result = parent.rowOperationsManager.addNewRow(tableRows: &rows, uuidKeyForms: uuidKeys)
            addResult = result
            return result?.delta ?? .none
        }

        guard let result = addResult else { return }

        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(result.delta)
        selectAndEditInsertedRow(result.rowID, tabId: tabId, skipping: result.prefilledColumns)
    }

    func deleteSelectedRows(indices: Set<Int>) {
        guard parent.canEditActiveResult,
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              !indices.isEmpty else { return }

        let tabId = tab.id
        let displayIDs = parent.activeGridDisplayIDs

        var deleteResult = RowOperationsManager.DeleteRowsResult(
            nextRowToSelect: -1,
            physicallyRemovedIndices: [],
            delta: .none
        )
        parent.mutateActiveTableRows(for: tabId) { rows in
            let result = parent.rowOperationsManager.deleteSelectedRows(
                selectedIndices: indices,
                displayIDs: displayIDs,
                tableRows: &rows
            )
            deleteResult = result
            return result.delta
        }

        guard deleteResult.stagedRowCount > 0 else { return }

        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }

        if !deleteResult.physicallyRemovedIndices.isEmpty {
            parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(deleteResult.delta)
        } else {
            parent.dataTabDelegate?.tableViewCoordinator?.invalidateCachesForUndoRedo()
        }

        guard selectionPointsTheGrid else { return }
        let displayCount = parent.activeGridDisplayIDs?.count
            ?? parent.tabSessionRegistry.tableRows(for: tabId).count
        if deleteResult.nextRowToSelect >= 0 && deleteResult.nextRowToSelect < displayCount {
            parent.selectionState.indices = [deleteResult.nextRowToSelect]
        } else {
            parent.selectionState.indices.removeAll()
        }
    }

    func duplicateSelectedRow(index: Int) {
        guard parent.canEditActiveResult,
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              tab.tableContext.tableName != nil else { return }

        let tabId = tab.id
        let tableRows = parent.tabSessionRegistry.tableRows(for: tabId)
        guard tableRows.hasAuthoritativeSchema,
              let storageIndex = DisplayRowMapping.rowIndex(
                  forDisplay: index, displayIDs: parent.activeGridDisplayIDs, in: tableRows
              ) else { return }

        parent.dataTabDelegate?.tableViewCoordinator?.commitActiveCellEdit()

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
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(result.delta)
        selectAndEditInsertedRow(result.rowID, tabId: tabId, skipping: result.prefilledColumns)
    }

    /// The caret skips a key the row was given a fresh UUID for, so the first keystroke does not replace it.
    private func selectAndEditInsertedRow(_ rowID: RowID, tabId: UUID, skipping prefilled: Set<Int>) {
        guard selectionPointsTheGrid,
              let displayIndex = displayIndex(of: rowID, tabId: tabId) else { return }
        parent.selectionState.indices = [displayIndex]
        parent.dataTabDelegate?.tableViewCoordinator?.beginEditingFirstEditableColumn(
            displayRow: displayIndex, skipping: prefilled
        )
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

    /// The key columns a new, duplicated or pasted row gets a fresh UUID in: a UUID key the server does not fill,
    /// whose `__DEFAULT__` would leave the key out of the INSERT. Asked of `SetValueOptions`, so a foreign key, a
    /// read-only column or a writer that cannot store UUID text gets none, exactly as Generate UUID is hidden.
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

    private func displayIndex(of rowID: RowID, tabId: UUID) -> Int? {
        DisplayRowMapping.displayIndex(
            forRowID: rowID,
            displayIDs: parent.activeGridDisplayIDs,
            in: parent.tabSessionRegistry.tableRows(for: tabId)
        )
    }

    private func displayIndices(of rowIDs: Set<RowID>, tabId: UUID) -> Set<Int> {
        guard let displayIDs = parent.activeGridDisplayIDs else {
            let tableRows = parent.tabSessionRegistry.tableRows(for: tabId)
            return Set(rowIDs.compactMap { tableRows.index(of: $0) })
        }
        return Set(displayIDs.indices.filter { rowIDs.contains(displayIDs[$0]) })
    }

    /// Ends the typed run an inspector field was building, so the next thing to register an undo
    /// step lands after it rather than inside it.
    func endInspectorEditRun() {
        parent.changeManager.endCoalescedUndoRun()
    }

    /// Stages a row inspector field edit exactly as the grid's own cell editor stages one: the
    /// change, the shared `TableRows` buffer both surfaces read, and the repaint.
    ///
    /// The rows are named by `RowID` rather than by the display positions the selection carries,
    /// and each contributes its own `oldValue`. A shared one is wrong the moment a multi-row
    /// selection disagrees on the field, where the inspector holds no value for it at all.
    ///
    /// `isExpression` stages `value`, SQL from `CellExpressionVocabulary`, to be written unquoted.
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

    /// A value of its own for each row, one undo step for all of them.
    func stageInspectorFieldValues(columnIndex: Int, valuesByRow: [RowID: PluginCellValue]) {
        stageInspectorEdits(valuesByRow: valuesByRow, columnIndex: columnIndex, continuity: .discrete)
    }

    /// Puts a field back to the values the inspector was configured with.
    ///
    /// A field the selected rows disagree on has no value of its own, and clearing it asks for each
    /// row's own value back rather than for one value across all of them.
    ///
    /// `absentRowIDs` are the rows that had no field for the column, which it goes back to missing, and
    /// `expressionRowIDs` the rows whose value was staged SQL, which goes back as SQL rather than as text.
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

    /// Takes the field out of every row the inspector is showing, for an engine that tells a
    /// missing field from NULL.
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
        /// Before the rows are touched, not after: a column the server owns is refused when the
        /// change is recorded, and editing here first would paint a value into the grid that no
        /// statement will ever carry.
        guard parent.changeManager.isColumnWritable(columnName) else { return }

        var edits: [(row: Int, column: Int, value: PluginCellValue)] = []
        var removedCells: Set<CellPosition> = []
        var editedRowIDs: Set<RowID> = []
        for (rowID, value) in valuesByRow {
            guard let storageRow = tableRows.index(of: rowID) else { continue }
            let row = tableRows.rows[storageRow]
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
            editedRowIDs.insert(rowID)
        }
        guard !edits.isEmpty else { return }

        parent.mutateActiveTableRows(for: tabId) { rows in rows.editMany(edits, absentCells: removedCells) }
        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
        repaintInspectorEdit(rowIDs: editedRowIDs, columnIndex: columnIndex, in: tableRows)
        parent.inspectorRowContentChanged.send()
    }

    /// `editMany` reports the rows it changed by their position in storage, and the grid reads a
    /// delta's rows as display positions, so a sort or a value filter would repaint the wrong ones.
    ///
    /// Resolved in one pass over the display order rather than a search per row, because that order
    /// is as long as the result.
    private func repaintInspectorEdit(rowIDs: Set<RowID>, columnIndex: Int, in tableRows: TableRows) {
        var positions: Set<CellPosition> = []
        if let displayIDs = parent.activeGridDisplayIDs {
            for (displayRow, rowID) in displayIDs.enumerated() where rowIDs.contains(rowID) {
                positions.insert(CellPosition(row: displayRow, column: columnIndex))
            }
        } else {
            for rowID in rowIDs {
                guard let displayRow = tableRows.index(of: rowID) else { continue }
                positions.insert(CellPosition(row: displayRow, column: columnIndex))
            }
        }
        guard !positions.isEmpty else { return }
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(.cellsChanged(positions))
    }

    func handleUndoResult(_ result: UndoResult) {
        guard let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex else { return }

        let tabId = tab.id

        var application = RowOperationsManager.UndoApplicationResult(adjustedSelection: nil, delta: .none)
        parent.mutateActiveTableRows(for: tabId) { rows in
            let applied = parent.rowOperationsManager.applyUndoResult(result, tableRows: &rows)
            application = applied
            return applied.delta
        }

        if let adjustedSelection = application.adjustedSelection {
            parent.selectionState.indices = adjustedSelection
        }

        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
        parent.dataTabDelegate?.tableViewCoordinator?.invalidateCachesForUndoRedo()
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(application.delta)
        /// The row inspector reads its fields from the `TableRows` this just rewrote, and nothing
        /// else in `InspectorTrigger` moves on an undo.
        parent.gridDisplayRevision &+= 1
    }

    func copySelectedRowsToClipboard(indices: Set<Int>) {
        guard let (tab, _) = parent.tabManager.selectedTabAndIndex, !indices.isEmpty else { return }
        let tableRows = parent.tabSessionRegistry.tableRows(for: tab.id)
        parent.rowOperationsManager.copySelectedRowsToClipboard(
            selectedIndices: indices,
            tableRows: tableRows,
            displayIDs: parent.activeGridDisplayIDs,
            visibleColumnIndices: parent.dataTabDelegate?.tableViewCoordinator?.visibleColumnDataIndices()
        )
    }

    func copySelectedRowsWithHeaders(indices: Set<Int>) {
        guard let (tab, _) = parent.tabManager.selectedTabAndIndex, !indices.isEmpty else { return }
        let tableRows = parent.tabSessionRegistry.tableRows(for: tab.id)
        parent.rowOperationsManager.copySelectedRowsToClipboard(
            selectedIndices: indices,
            tableRows: tableRows,
            displayIDs: parent.activeGridDisplayIDs,
            includeHeaders: true,
            visibleColumnIndices: parent.dataTabDelegate?.tableViewCoordinator?.visibleColumnDataIndices()
        )
    }

    func copySelectedRowsAsJson(indices: Set<Int>) {
        guard let (tab, _) = parent.tabManager.selectedTabAndIndex, !indices.isEmpty else { return }
        let output = ResultJsonSerializer.serialize(
            tableRows: parent.tabSessionRegistry.tableRows(for: tab.id),
            displayIDs: parent.activeGridDisplayIDs,
            selectedDisplayIndices: indices,
            columns: VisibleColumnProjection(
                indices: parent.dataTabDelegate?.tableViewCoordinator?.visibleColumnDataIndices()
            )
        )
        guard output.rowCount > 0 else { return }
        ClipboardService.shared.writeText(output.json)
    }

    func pasteRows() {
        guard parent.canEditActiveResult,
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              tab.tabType == .table else { return }

        let tabId = tab.id
        /// Pasted rows hand the columns the server owns back to it, which only the schema names, so pasting waits for
        /// it the way Add Row does rather than staging an identity value the save would send.
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

        let newIndices = displayIndices(of: Set(pasteResult.pastedRows.map(\.rowID)), tabId: tabId)
        if selectionPointsTheGrid {
            parent.selectionState.indices = newIndices
        }

        parent.tabManager.mutate(at: tabIndex) { tab in
            tab.selectedRowIndices = newIndices
            /// The pasted rows are the selection now. Left behind, the stored rectangle would
            /// outrank them in `selectedDisplayRows` and come back instead of them.
            tab.cellSelection = .empty
            tab.hasUserInteraction = true
        }
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(pasteResult.delta)
    }

    func updateCellInTab(rowIndex: Int, columnIndex: Int, value: PluginCellValue) {
        guard let (_, tabIndex) = parent.tabManager.selectedTabAndIndex else { return }
        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
    }
}
