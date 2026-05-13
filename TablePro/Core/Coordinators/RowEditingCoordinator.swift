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
        parent.querySortCache.removeValue(forKey: tabId)
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(result.delta)
        parent.dataTabDelegate?.tableViewCoordinator?.beginEditing(displayRow: result.rowIndex, column: 0)
    }

    func deleteSelectedRows(indices: Set<Int>) {
        guard !parent.safeModeLevel.blocksAllWrites,
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              tab.tableContext.isEditable,
              !indices.isEmpty else { return }

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
            parent.querySortCache.removeValue(forKey: tabId)
            parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(deleteResult.delta)
        } else {
            parent.dataTabDelegate?.tableViewCoordinator?.invalidateCachesForUndoRedo()
        }
    }

    func duplicateSelectedRow(index: Int) {
        guard !parent.safeModeLevel.blocksAllWrites,
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              tab.tableContext.isEditable,
              tab.tableContext.tableName != nil else { return }

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
        parent.querySortCache.removeValue(forKey: tabId)
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(result.delta)
        parent.dataTabDelegate?.tableViewCoordinator?.beginEditing(displayRow: result.rowIndex, column: 0)
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
        parent.querySortCache.removeValue(forKey: tabId)
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
        parent.querySortCache.removeValue(forKey: tabId)
        parent.dataTabDelegate?.tableViewCoordinator?.invalidateCachesForUndoRedo()
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(application.delta)
    }

    func copySelectedRowsToClipboard(indices: Set<Int>) {
        guard let (tab, _) = parent.tabManager.selectedTabAndIndex, !indices.isEmpty else { return }
        let tableRows = parent.tabSessionRegistry.tableRows(for: tab.id)
        parent.rowOperationsManager.copySelectedRowsToClipboard(
            selectedIndices: indices,
            tableRows: tableRows
        )
    }

    func copySelectedRowsWithHeaders(indices: Set<Int>) {
        guard let (tab, _) = parent.tabManager.selectedTabAndIndex, !indices.isEmpty else { return }
        let tableRows = parent.tabSessionRegistry.tableRows(for: tab.id)
        parent.rowOperationsManager.copySelectedRowsToClipboard(
            selectedIndices: indices,
            tableRows: tableRows,
            includeHeaders: true
        )
    }

    func copySelectedRowsAsJson(indices: Set<Int>) {
        guard let (tab, _) = parent.tabManager.selectedTabAndIndex, !indices.isEmpty else { return }
        let tableRows = parent.tabSessionRegistry.tableRows(for: tab.id)
        let rows = indices.sorted().compactMap { idx -> [PluginCellValue]? in
            guard idx >= 0, idx < tableRows.count else { return nil }
            return Array(tableRows.rows[idx].values)
        }
        guard !rows.isEmpty else { return }
        let converter = JsonRowConverter(
            columns: tableRows.columns,
            columnTypes: tableRows.columnTypes
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
        parent.querySortCache.removeValue(forKey: tabId)
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(pasteResult.delta)
    }

    func updateCellInTab(rowIndex: Int, columnIndex: Int, value: PluginCellValue) {
        guard let (_, tabIndex) = parent.tabManager.selectedTabAndIndex else { return }
        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
    }
}
