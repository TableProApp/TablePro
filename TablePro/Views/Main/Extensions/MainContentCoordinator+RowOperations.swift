import Foundation

extension MainContentCoordinator {
    func addNewRow() {
        guard !safeModeLevel.blocksAllWrites,
              let (tab, tabIndex) = tabManager.selectedTabAndIndex,
              tab.tableContext.isEditable,
              tab.tableContext.tableName != nil else { return }

        let tabId = tab.id
        let columnDefaults = tabSessionRegistry.tableRows(for: tabId).columnDefaults
        let columns = tabSessionRegistry.tableRows(for: tabId).columns

        dataTabDelegate?.tableViewCoordinator?.commitActiveCellEdit()

        var addResult: RowOperationsManager.AddNewRowResult?
        mutateActiveTableRows(for: tabId) { rows in
            let result = rowOperationsManager.addNewRow(
                columns: columns,
                columnDefaults: columnDefaults,
                tableRows: &rows
            )
            addResult = result
            return result?.delta ?? .none
        }

        guard let result = addResult else { return }

        selectionState.indices = [result.rowIndex]
        tabManager.tabs[tabIndex].hasUserInteraction = true
        querySortCache.removeValue(forKey: tabId)
        dataTabDelegate?.tableViewCoordinator?.applyDelta(result.delta)
        dataTabDelegate?.tableViewCoordinator?.beginEditing(displayRow: result.rowIndex, column: 0)
    }

    func deleteSelectedRows(indices: Set<Int>) {
        guard !safeModeLevel.blocksAllWrites,
              let (tab, tabIndex) = tabManager.selectedTabAndIndex,
              tab.tableContext.isEditable,
              !indices.isEmpty else { return }

        let tabId = tab.id

        var deleteResult = RowOperationsManager.DeleteRowsResult(
            nextRowToSelect: -1,
            physicallyRemovedIndices: [],
            delta: .none
        )
        mutateActiveTableRows(for: tabId) { rows in
            let result = rowOperationsManager.deleteSelectedRows(
                selectedIndices: indices,
                tableRows: &rows
            )
            deleteResult = result
            return result.delta
        }

        let totalRows = tabSessionRegistry.tableRows(for: tabId).count
        if deleteResult.nextRowToSelect >= 0 && deleteResult.nextRowToSelect < totalRows {
            selectionState.indices = [deleteResult.nextRowToSelect]
        } else {
            selectionState.indices.removeAll()
        }

        tabManager.tabs[tabIndex].hasUserInteraction = true

        if !deleteResult.physicallyRemovedIndices.isEmpty {
            querySortCache.removeValue(forKey: tabId)
            dataTabDelegate?.tableViewCoordinator?.applyDelta(deleteResult.delta)
        } else {
            dataTabDelegate?.tableViewCoordinator?.invalidateCachesForUndoRedo()
        }
    }

    func duplicateSelectedRow(index: Int) {
        guard !safeModeLevel.blocksAllWrites,
              let (tab, tabIndex) = tabManager.selectedTabAndIndex,
              tab.tableContext.isEditable,
              tab.tableContext.tableName != nil else { return }

        let tabId = tab.id
        let columns = tabSessionRegistry.tableRows(for: tabId).columns
        guard index >= 0, index < tabSessionRegistry.tableRows(for: tabId).count else { return }

        dataTabDelegate?.tableViewCoordinator?.commitActiveCellEdit()

        var dupResult: RowOperationsManager.AddNewRowResult?
        mutateActiveTableRows(for: tabId) { rows in
            let result = rowOperationsManager.duplicateRow(
                sourceRowIndex: index,
                columns: columns,
                tableRows: &rows
            )
            dupResult = result
            return result?.delta ?? .none
        }

        guard let result = dupResult else { return }

        selectionState.indices = [result.rowIndex]
        tabManager.tabs[tabIndex].hasUserInteraction = true
        querySortCache.removeValue(forKey: tabId)
        dataTabDelegate?.tableViewCoordinator?.applyDelta(result.delta)
        dataTabDelegate?.tableViewCoordinator?.beginEditing(displayRow: result.rowIndex, column: 0)
    }

    func undoInsertRow(at rowIndex: Int) {
        guard let (tab, _) = tabManager.selectedTabAndIndex else { return }
        let tabId = tab.id

        var undoResult = RowOperationsManager.UndoInsertRowResult(
            adjustedSelection: selectionState.indices,
            delta: .none
        )
        mutateActiveTableRows(for: tabId) { rows in
            let result = rowOperationsManager.undoInsertRow(
                at: rowIndex,
                tableRows: &rows,
                selectedIndices: selectionState.indices
            )
            undoResult = result
            return result.delta
        }

        selectionState.indices = undoResult.adjustedSelection
        querySortCache.removeValue(forKey: tabId)
        dataTabDelegate?.tableViewCoordinator?.applyDelta(undoResult.delta)
    }

    func handleUndoResult(_ result: UndoResult) {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex else { return }

        let tabId = tab.id

        var application = RowOperationsManager.UndoApplicationResult(adjustedSelection: nil, delta: .none)
        mutateActiveTableRows(for: tabId) { rows in
            let applied = rowOperationsManager.applyUndoResult(result, tableRows: &rows)
            application = applied
            return applied.delta
        }

        if let adjustedSelection = application.adjustedSelection {
            selectionState.indices = adjustedSelection
        }

        tabManager.tabs[tabIndex].hasUserInteraction = true
        querySortCache.removeValue(forKey: tabId)
        dataTabDelegate?.tableViewCoordinator?.invalidateCachesForUndoRedo()
        dataTabDelegate?.tableViewCoordinator?.applyDelta(application.delta)
    }

    func copySelectedRowsToClipboard(indices: Set<Int>) {
        guard let (tab, _) = tabManager.selectedTabAndIndex, !indices.isEmpty else { return }
        let tableRows = tabSessionRegistry.tableRows(for: tab.id)
        rowOperationsManager.copySelectedRowsToClipboard(
            selectedIndices: indices,
            tableRows: tableRows
        )
    }

    func copySelectedRowsWithHeaders(indices: Set<Int>) {
        guard let (tab, _) = tabManager.selectedTabAndIndex, !indices.isEmpty else { return }
        let tableRows = tabSessionRegistry.tableRows(for: tab.id)
        rowOperationsManager.copySelectedRowsToClipboard(
            selectedIndices: indices,
            tableRows: tableRows,
            includeHeaders: true
        )
    }

    func copySelectedRowsAsJson(indices: Set<Int>) {
        guard let (tab, _) = tabManager.selectedTabAndIndex, !indices.isEmpty else { return }
        let tableRows = tabSessionRegistry.tableRows(for: tab.id)
        let rows = indices.sorted().compactMap { idx -> [String?]? in
            guard idx >= 0, idx < tableRows.count else { return nil }
            return tableRows.rows[idx].values
        }
        guard !rows.isEmpty else { return }
        let converter = JsonRowConverter(
            columns: tableRows.columns,
            columnTypes: tableRows.columnTypes
        )
        ClipboardService.shared.writeText(converter.generateJson(rows: rows))
    }

    func pasteRows() {
        guard !safeModeLevel.blocksAllWrites,
              let (tab, tabIndex) = tabManager.selectedTabAndIndex,
              tab.tabType == .table else { return }

        let tabId = tab.id
        let columns = tabSessionRegistry.tableRows(for: tabId).columns

        var pasteResult = RowOperationsManager.PasteRowsResult(pastedRows: [], delta: .none)
        mutateActiveTableRows(for: tabId) { rows in
            let result = rowOperationsManager.pasteRowsFromClipboard(
                columns: columns,
                primaryKeyColumns: changeManager.primaryKeyColumns,
                tableRows: &rows
            )
            pasteResult = result
            return result.delta
        }

        guard !pasteResult.pastedRows.isEmpty else { return }

        let newIndices = Set(pasteResult.pastedRows.map { $0.rowIndex })
        selectionState.indices = newIndices

        tabManager.tabs[tabIndex].selectedRowIndices = newIndices
        tabManager.tabs[tabIndex].hasUserInteraction = true
        querySortCache.removeValue(forKey: tabId)
        dataTabDelegate?.tableViewCoordinator?.applyDelta(pasteResult.delta)
    }

    func updateCellInTab(rowIndex: Int, columnIndex: Int, value: String?) {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex else { return }
        let tabId = tab.id
        let delta = mutateActiveTableRows(for: tabId) { rows in
            rows.edit(row: rowIndex, column: columnIndex, value: value)
        }
        tabManager.tabs[tabIndex].hasUserInteraction = true
        dataTabDelegate?.tableViewCoordinator?.applyDelta(delta)
    }
}
