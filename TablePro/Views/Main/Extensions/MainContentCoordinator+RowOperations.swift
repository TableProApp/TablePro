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

        guard let result = rowOperationsManager.addNewRow(
            columns: tab.resultColumns,
            columnDefaults: tab.columnDefaults,
            resultRows: &tabManager.tabs[tabIndex].resultRows
        ) else { return }

        selectionState.indices = [result.rowIndex]
        editingCell = CellPosition(row: result.rowIndex, column: 0)
        tabManager.tabs[tabIndex].hasUserInteraction = true
        tabManager.tabs[tabIndex].resultVersion += 1
    }

    func deleteSelectedRows(indices: Set<Int>) {
        guard !safeModeLevel.blocksAllWrites,
              let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count,
              tabManager.tabs[tabIndex].tableContext.isEditable,
              !indices.isEmpty else { return }

        let nextRow = rowOperationsManager.deleteSelectedRows(
            selectedIndices: indices,
            resultRows: &tabManager.tabs[tabIndex].resultRows
        )

        if nextRow >= 0 && nextRow < tabManager.tabs[tabIndex].resultRows.count {
            selectionState.indices = [nextRow]
        } else {
            selectionState.indices.removeAll()
        }

        tabManager.tabs[tabIndex].hasUserInteraction = true
        tabManager.tabs[tabIndex].resultVersion += 1
    }

    func duplicateSelectedRow(index: Int, editingCell: inout CellPosition?) {
        guard !safeModeLevel.blocksAllWrites,
              let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        let tab = tabManager.tabs[tabIndex]
        guard tab.tableContext.isEditable, tab.tableContext.tableName != nil,
              index < tab.resultRows.count else { return }

        guard let result = rowOperationsManager.duplicateRow(
            sourceRowIndex: index,
            columns: tab.resultColumns,
            resultRows: &tabManager.tabs[tabIndex].resultRows
        ) else { return }

        selectionState.indices = [result.rowIndex]
        editingCell = CellPosition(row: result.rowIndex, column: 0)
        tabManager.tabs[tabIndex].hasUserInteraction = true
        tabManager.tabs[tabIndex].resultVersion += 1
    }

    func undoInsertRow(at rowIndex: Int) {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        selectionState.indices = rowOperationsManager.undoInsertRow(
            at: rowIndex,
            resultRows: &tabManager.tabs[tabIndex].resultRows,
            selectedIndices: selectionState.indices
        )
        tabManager.tabs[tabIndex].resultVersion += 1
    }

    func undoLastChange() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        if let adjustedSelection = rowOperationsManager.undoLastChange(
            resultRows: &tabManager.tabs[tabIndex].resultRows
        ) {
            selectionState.indices = adjustedSelection
        }

        tabManager.tabs[tabIndex].hasUserInteraction = true
        tabManager.tabs[tabIndex].resultVersion += 1
    }

    func redoLastChange() {
        guard let tabIndex = tabManager.selectedTabIndex,
              tabIndex < tabManager.tabs.count else { return }

        let tab = tabManager.tabs[tabIndex]
        _ = rowOperationsManager.redoLastChange(
            resultRows: &tabManager.tabs[tabIndex].resultRows,
            columns: tab.resultColumns
        )

        tabManager.tabs[tabIndex].hasUserInteraction = true
        tabManager.tabs[tabIndex].resultVersion += 1
    }

    func copySelectedRowsToClipboard(indices: Set<Int>) {
        guard let index = tabManager.selectedTabIndex,
              !indices.isEmpty else { return }

        let tab = tabManager.tabs[index]
        rowOperationsManager.copySelectedRowsToClipboard(
            selectedIndices: indices,
            resultRows: tab.resultRows
        )
    }

    func copySelectedRowsWithHeaders(indices: Set<Int>) {
        guard let index = tabManager.selectedTabIndex,
              !indices.isEmpty else { return }

        let tab = tabManager.tabs[index]
        rowOperationsManager.copySelectedRowsToClipboard(
            selectedIndices: indices,
            resultRows: tab.resultRows,
            columns: tab.resultColumns,
            includeHeaders: true
        )
    }

    func copySelectedRowsAsJson(indices: Set<Int>) {
        guard let index = tabManager.selectedTabIndex,
              !indices.isEmpty else { return }
        let tab = tabManager.tabs[index]
        let rows = indices.sorted().compactMap { idx -> [String?]? in
            guard idx < tab.resultRows.count else { return nil }
            return tab.resultRows[idx]
        }
        guard !rows.isEmpty else { return }
        let converter = JsonRowConverter(
            columns: tab.resultColumns,
            columnTypes: tab.columnTypes
        )
        ClipboardService.shared.writeText(converter.generateJson(rows: rows))
    }

    func pasteRows(editingCell: inout CellPosition?) {
        guard !safeModeLevel.blocksAllWrites,
              let index = tabManager.selectedTabIndex else { return }

        var tab = tabManager.tabs[index]

        guard tab.tabType == .table else { return }

        let pastedRows = rowOperationsManager.pasteRowsFromClipboard(
            columns: tab.resultColumns,
            primaryKeyColumns: changeManager.primaryKeyColumns,
            resultRows: &tab.resultRows
        )

        tabManager.tabs[index].resultRows = tab.resultRows
        tabManager.tabs[index].resultVersion += 1

        if !pastedRows.isEmpty {
            let newIndices = Set(pastedRows.map { $0.rowIndex })
            selectionState.indices = newIndices

            tabManager.tabs[index].selectedRowIndices = newIndices
            tabManager.tabs[index].hasUserInteraction = true
        }
    }

    // MARK: - Cell Operations

    func updateCellInTab(rowIndex: Int, columnIndex: Int, value: String?) {
        guard let index = tabManager.selectedTabIndex,
              rowIndex < tabManager.tabs[index].resultRows.count else { return }

        tabManager.tabs[index].resultRows[rowIndex][columnIndex] = value
        tabManager.tabs[index].hasUserInteraction = true
    }
}
