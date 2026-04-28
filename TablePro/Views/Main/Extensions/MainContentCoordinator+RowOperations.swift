//
//  MainContentCoordinator+RowOperations.swift
//  TablePro
//
//  Row manipulation operations for MainContentCoordinator
//

import Foundation

extension MainContentCoordinator {
    // MARK: - Row Operations

    func addNewRow(editingCell: inout CellPosition?) {
        guard !safeModeLevel.blocksAllWrites,
              let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        let tab = tabManager.tabs[tabIndex]
        guard tab.tableContext.isEditable, tab.tableContext.tableName != nil else { return }

        let buffer = rowDataStore.buffer(for: tab.id)
        guard let result = rowOperationsManager.addNewRow(
            columns: buffer.columns,
            columnDefaults: buffer.columnDefaults,
            resultRows: &buffer.rows
        ) else { return }

        selectionState.indices = [result.rowIndex]
        editingCell = CellPosition(row: result.rowIndex, column: 0)
        tabManager.tabs[tabIndex].hasUserInteraction = true
        querySortCache.removeValue(forKey: tab.id)
        dataTabDelegate?.dataGridDidInsertRows(at: IndexSet(integer: result.rowIndex))
    }

    func deleteSelectedRows(indices: Set<Int>) {
        guard !safeModeLevel.blocksAllWrites,
              let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              tabManager.tabs[tabIndex].tableContext.isEditable,
              !indices.isEmpty else { return }

        let tabId = tabManager.tabs[tabIndex].id
        let buffer = rowDataStore.buffer(for: tabId)
        let result = rowOperationsManager.deleteSelectedRows(
            selectedIndices: indices,
            resultRows: &buffer.rows
        )

        if result.nextRowToSelect >= 0
            && result.nextRowToSelect < buffer.rows.count {
            selectionState.indices = [result.nextRowToSelect]
        } else {
            selectionState.indices.removeAll()
        }

        tabManager.tabs[tabIndex].hasUserInteraction = true

        if !result.physicallyRemovedIndices.isEmpty {
            querySortCache.removeValue(forKey: tabId)
            dataTabDelegate?.dataGridDidRemoveRows(
                at: IndexSet(result.physicallyRemovedIndices)
            )
        }
    }

    func duplicateSelectedRow(index: Int, editingCell: inout CellPosition?) {
        guard !safeModeLevel.blocksAllWrites,
              let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        let tab = tabManager.tabs[tabIndex]
        guard tab.tableContext.isEditable, tab.tableContext.tableName != nil else { return }
        let buffer = rowDataStore.buffer(for: tab.id)
        guard index < buffer.rows.count else { return }

        guard let result = rowOperationsManager.duplicateRow(
            sourceRowIndex: index,
            columns: buffer.columns,
            resultRows: &buffer.rows
        ) else { return }

        selectionState.indices = [result.rowIndex]
        editingCell = CellPosition(row: result.rowIndex, column: 0)
        tabManager.tabs[tabIndex].hasUserInteraction = true
        querySortCache.removeValue(forKey: tab.id)
        dataTabDelegate?.dataGridDidInsertRows(at: IndexSet(integer: result.rowIndex))
    }

    func undoInsertRow(at rowIndex: Int) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        let tabId = tabManager.tabs[tabIndex].id
        let buffer = rowDataStore.buffer(for: tabId)
        selectionState.indices = rowOperationsManager.undoInsertRow(
            at: rowIndex,
            resultRows: &buffer.rows,
            selectedIndices: selectionState.indices
        )
        querySortCache.removeValue(forKey: tabId)
        dataTabDelegate?.dataGridDidRemoveRows(at: IndexSet(integer: rowIndex))
    }

    func handleUndoResult(_ result: UndoResult) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        let tab = tabManager.tabs[tabIndex]
        let buffer = rowDataStore.buffer(for: tab.id)
        if let adjustedSelection = rowOperationsManager.applyUndoResult(
            result, resultRows: &buffer.rows
        ) {
            selectionState.indices = adjustedSelection
        }

        tabManager.tabs[tabIndex].hasUserInteraction = true
        querySortCache.removeValue(forKey: tab.id)
        dataTabDelegate?.tableViewCoordinator?.invalidateCachesForUndoRedo()
    }

    func copySelectedRowsToClipboard(indices: Set<Int>) {
        guard let index = tabManager.selectedTabIndex,
              !indices.isEmpty else { return }

        let tab = tabManager.tabs[index]
        let buffer = rowDataStore.buffer(for: tab.id)
        rowOperationsManager.copySelectedRowsToClipboard(
            selectedIndices: indices,
            resultRows: buffer.rows
        )
    }

    func copySelectedRowsWithHeaders(indices: Set<Int>) {
        guard let index = tabManager.selectedTabIndex,
              !indices.isEmpty else { return }

        let tab = tabManager.tabs[index]
        let buffer = rowDataStore.buffer(for: tab.id)
        rowOperationsManager.copySelectedRowsToClipboard(
            selectedIndices: indices,
            resultRows: buffer.rows,
            columns: buffer.columns,
            includeHeaders: true
        )
    }

    func copySelectedRowsAsJson(indices: Set<Int>) {
        guard let index = tabManager.selectedTabIndex,
              !indices.isEmpty else { return }
        let tab = tabManager.tabs[index]
        let buffer = rowDataStore.buffer(for: tab.id)
        let rows = indices.sorted().compactMap { idx -> [String?]? in
            guard idx < buffer.rows.count else { return nil }
            return buffer.rows[idx]
        }
        guard !rows.isEmpty else { return }
        let converter = JsonRowConverter(
            columns: buffer.columns,
            columnTypes: buffer.columnTypes
        )
        ClipboardService.shared.writeText(converter.generateJson(rows: rows))
    }

    func pasteRows(editingCell: inout CellPosition?) {
        guard !safeModeLevel.blocksAllWrites,
              let index = tabManager.selectedTabIndex else { return }

        let tab = tabManager.tabs[index]

        guard tab.tabType == .table else { return }

        let buffer = rowDataStore.buffer(for: tab.id)
        let pastedRows = rowOperationsManager.pasteRowsFromClipboard(
            columns: buffer.columns,
            primaryKeyColumns: changeManager.primaryKeyColumns,
            resultRows: &buffer.rows
        )

        if !pastedRows.isEmpty {
            let newIndices = Set(pastedRows.map { $0.rowIndex })
            selectionState.indices = newIndices

            tabManager.tabs[index].selectedRowIndices = newIndices
            tabManager.tabs[index].hasUserInteraction = true
            querySortCache.removeValue(forKey: tab.id)
            dataTabDelegate?.dataGridDidInsertRows(at: IndexSet(newIndices))
        }
    }

    // MARK: - Cell Operations

    func updateCellInTab(rowIndex: Int, columnIndex: Int, value: String?) {
        guard let index = tabManager.selectedTabIndex else { return }
        let tabId = tabManager.tabs[index].id
        let buffer = rowDataStore.buffer(for: tabId)
        guard rowIndex < buffer.rows.count else { return }

        buffer.rows[rowIndex][columnIndex] = value
        tabManager.tabs[index].hasUserInteraction = true
    }
}
