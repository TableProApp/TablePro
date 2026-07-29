//
//  RowEditingCoordinator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor @Observable
final class RowEditingCoordinator {
    @ObservationIgnored unowned let parent: MainContentCoordinator

    init(parent: MainContentCoordinator) {
        self.parent = parent
    }

    // MARK: - Row Operations

    func addNewRow() {
        guard !parent.safeModeLevel.blocksAllWrites,
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              tab.tableContext.isEditable,
              tab.tableContext.tableName != nil else { return }

        let tabId = tab.id
        let columnDefaults = parent.tabSessionRegistry.tableRows(for: tabId).columnDefaults
        let columns = parent.tabSessionRegistry.tableRows(for: tabId).columns

        parent.dataTabDelegate?.tableViewCoordinator?.commitActiveCellEdit()

        var addResult: RowOperationsManager.AddNewRowResult?
        parent.mutateActiveTableRows(for: tabId) { rows in
            let result = parent.rowOperationsManager.addNewRow(
                columns: columns,
                columnDefaults: columnDefaults,
                tableRows: &rows
            )
            addResult = result
            return result?.delta ?? .none
        }

        guard let result = addResult else { return }

        parent.selectionState.indices = [result.rowIndex]
        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(result.delta)
        parent.dataTabDelegate?.tableViewCoordinator?.beginEditing(displayRow: result.rowIndex, column: 0)
    }

    func deleteSelectedRows(indices: Set<Int>) {
        guard !parent.safeModeLevel.blocksAllWrites,
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              tab.tableContext.isEditable,
              !indices.isEmpty else { return }

        if parent.activeGridDisplayIDs != nil {
            deleteFilteredRows(indices: indices, tab: tab, tabIndex: tabIndex)
            return
        }

        let tabId = tab.id

        var deleteResult = RowOperationsManager.DeleteRowsResult(
            nextRowToSelect: -1,
            physicallyRemovedIndices: [],
            delta: .none
        )
        parent.mutateActiveTableRows(for: tabId) { rows in
            let result = parent.rowOperationsManager.deleteSelectedRows(
                selectedIndices: indices,
                tableRows: &rows
            )
            deleteResult = result
            return result.delta
        }

        let totalRows = parent.tabSessionRegistry.tableRows(for: tabId).count
        if deleteResult.nextRowToSelect >= 0 && deleteResult.nextRowToSelect < totalRows {
            parent.selectionState.indices = [deleteResult.nextRowToSelect]
        } else {
            parent.selectionState.indices.removeAll()
        }

        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }

        if !deleteResult.physicallyRemovedIndices.isEmpty {
            parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(deleteResult.delta)
        } else {
            parent.dataTabDelegate?.tableViewCoordinator?.invalidateCachesForUndoRedo()
        }
    }

    private func deleteFilteredRows(indices: Set<Int>, tab: QueryTab, tabIndex: Int) {
        let tabId = tab.id
        let displayIDs = parent.activeGridDisplayIDs
        let tableRows = parent.tabSessionRegistry.tableRows(for: tabId)

        var existingRows: [(displayIndex: Int, originalRow: [PluginCellValue])] = []
        var insertedStorageIndices: [Int] = []
        for displayIndex in indices {
            guard let storageIndex = DisplayRowMapping.rowIndex(
                forDisplay: displayIndex, displayIDs: displayIDs, in: tableRows
            ) else { continue }
            let row = tableRows.rows[storageIndex]
            if row.id.isInserted {
                insertedStorageIndices.append(storageIndex)
            } else if !parent.changeManager.isRowDeleted(displayIndex) {
                existingRows.append((displayIndex: displayIndex, originalRow: Array(row.values)))
            }
        }

        guard !existingRows.isEmpty || !insertedStorageIndices.isEmpty else { return }

        var deleteResult = RowOperationsManager.DeleteRowsResult(
            nextRowToSelect: -1, physicallyRemovedIndices: [], delta: .none
        )
        parent.mutateActiveTableRows(for: tabId) { rows in
            let result = parent.rowOperationsManager.deleteRows(
                existingRows: existingRows,
                insertedStorageIndices: insertedStorageIndices,
                tableRows: &rows
            )
            deleteResult = result
            return result.delta
        }

        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }

        if !deleteResult.physicallyRemovedIndices.isEmpty {
            parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(deleteResult.delta)
        } else {
            parent.dataTabDelegate?.tableViewCoordinator?.invalidateCachesForUndoRedo()
        }

        let displayCount = parent.dataTabDelegate?.tableViewCoordinator?.displayIDs?.count
            ?? parent.tabSessionRegistry.tableRows(for: tabId).count
        if let minSelected = indices.min(), displayCount > 0 {
            parent.selectionState.indices = [min(minSelected, displayCount - 1)]
        } else {
            parent.selectionState.indices = []
        }
    }

    func duplicateSelectedRow(index: Int) {
        guard !parent.safeModeLevel.blocksAllWrites,
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              tab.tableContext.isEditable,
              tab.tableContext.tableName != nil else { return }

        if parent.activeGridDisplayIDs != nil {
            duplicateFilteredRow(displayIndex: index, tab: tab, tabIndex: tabIndex)
            return
        }

        let tabId = tab.id
        let columns = parent.tabSessionRegistry.tableRows(for: tabId).columns
        guard index >= 0, index < parent.tabSessionRegistry.tableRows(for: tabId).count else { return }

        parent.dataTabDelegate?.tableViewCoordinator?.commitActiveCellEdit()

        var dupResult: RowOperationsManager.AddNewRowResult?
        parent.mutateActiveTableRows(for: tabId) { rows in
            let result = parent.rowOperationsManager.duplicateRow(
                sourceRowIndex: index,
                columns: columns,
                tableRows: &rows
            )
            dupResult = result
            return result?.delta ?? .none
        }

        guard let result = dupResult else { return }

        parent.selectionState.indices = [result.rowIndex]
        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(result.delta)
        parent.dataTabDelegate?.tableViewCoordinator?.beginEditing(displayRow: result.rowIndex, column: 0)
    }

    private func duplicateFilteredRow(displayIndex: Int, tab: QueryTab, tabIndex: Int) {
        let tabId = tab.id
        let tableRows = parent.tabSessionRegistry.tableRows(for: tabId)
        let columns = tableRows.columns
        guard let storageIndex = DisplayRowMapping.rowIndex(
            forDisplay: displayIndex, displayIDs: parent.activeGridDisplayIDs, in: tableRows
        ), storageIndex >= 0, storageIndex < tableRows.count else { return }

        parent.dataTabDelegate?.tableViewCoordinator?.commitActiveCellEdit()

        var dupResult: RowOperationsManager.AddNewRowResult?
        parent.mutateActiveTableRows(for: tabId) { rows in
            let result = parent.rowOperationsManager.duplicateRow(
                sourceRowIndex: storageIndex,
                columns: columns,
                tableRows: &rows
            )
            dupResult = result
            return result?.delta ?? .none
        }

        guard let result = dupResult else { return }

        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(result.delta)

        let displayCount = parent.dataTabDelegate?.tableViewCoordinator?.displayIDs?.count
            ?? parent.tabSessionRegistry.tableRows(for: tabId).count
        let newDisplayIndex = displayCount - 1
        guard newDisplayIndex >= 0 else { return }
        parent.selectionState.indices = [newDisplayIndex]
        parent.dataTabDelegate?.tableViewCoordinator?.beginEditing(displayRow: newDisplayIndex, column: 0)
    }

    func undoInsertRow(at rowIndex: Int) {
        guard let (tab, _) = parent.tabManager.selectedTabAndIndex else { return }
        let tabId = tab.id

        var undoResult = RowOperationsManager.UndoInsertRowResult(
            adjustedSelection: parent.selectionState.indices,
            delta: .none
        )
        parent.mutateActiveTableRows(for: tabId) { rows in
            let result = parent.rowOperationsManager.undoInsertRow(
                at: rowIndex,
                tableRows: &rows,
                selectedIndices: parent.selectionState.indices
            )
            undoResult = result
            return result.delta
        }

        parent.selectionState.indices = undoResult.adjustedSelection
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(undoResult.delta)
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
        let tableRows = parent.tabSessionRegistry.tableRows(for: tab.id)
        let displayIDs = parent.activeGridDisplayIDs
        let projection = VisibleColumnProjection(
            indices: parent.dataTabDelegate?.tableViewCoordinator?.visibleColumnDataIndices()
        )
        let rows = indices.sorted().compactMap { displayIndex -> [PluginCellValue]? in
            DisplayRowMapping.row(forDisplay: displayIndex, displayIDs: displayIDs, in: tableRows)
                .map { projection.values(Array($0.values)) }
        }
        guard !rows.isEmpty else { return }
        let converter = JsonRowConverter(
            columns: projection.columns(tableRows.columns),
            columnTypes: projection.columnTypes(tableRows.columnTypes)
        )
        ClipboardService.shared.writeText(converter.generateJson(rows: rows))
    }

    func pasteRows() {
        guard !parent.safeModeLevel.blocksAllWrites,
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              tab.tabType == .table else { return }

        let tabId = tab.id
        let columns = parent.tabSessionRegistry.tableRows(for: tabId).columns

        var pasteResult = RowOperationsManager.PasteRowsResult(pastedRows: [], delta: .none)
        parent.mutateActiveTableRows(for: tabId) { rows in
            let result = parent.rowOperationsManager.pasteRowsFromClipboard(
                columns: columns,
                primaryKeyColumns: parent.changeManager.primaryKeyColumns,
                tableRows: &rows
            )
            pasteResult = result
            return result.delta
        }

        guard !pasteResult.pastedRows.isEmpty else { return }

        let newIndices = Set(pasteResult.pastedRows.map { $0.rowIndex })
        parent.selectionState.indices = newIndices

        parent.tabManager.mutate(at: tabIndex) { tab in
            tab.selectedRowIndices = newIndices
            tab.hasUserInteraction = true
        }
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(pasteResult.delta)
    }

    func updateCellInTab(rowIndex: Int, columnIndex: Int, value: PluginCellValue) {
        guard let (_, tabIndex) = parent.tabManager.selectedTabAndIndex else { return }
        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
    }
}
