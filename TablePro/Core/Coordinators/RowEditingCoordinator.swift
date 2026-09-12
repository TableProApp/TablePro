//
//  RowEditingCoordinator.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor @Observable
final class RowEditingCoordinator {
    @ObservationIgnored unowned let parent: MainContentCoordinator

    /// A save is between assembling its statements and hearing back.
    ///
    /// Nothing clears the pending changes until the write returns, so a second Cmd+S inside the
    /// round trip finds them still there, assembles the same statements again and commits them
    /// twice. Over a slow link that is easy to do by accident.
    @ObservationIgnored private(set) var isSaveInFlight = false

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
        guard !parent.safeModeLevel.blocksAllWrites,
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              tab.tableContext.isEditable,
              tab.tableContext.tableName != nil else { return }

        let tabId = tab.id
        /// A new row is pre-filled from the schema's account of which columns the server owns, so
        /// staging one before that account exists writes NULL into an identity column.
        guard parent.tabSessionRegistry.tableRows(for: tabId).hasAuthoritativeSchema else { return }

        parent.dataTabDelegate?.tableViewCoordinator?.commitActiveCellEdit()

        var addResult: RowOperationsManager.AddNewRowResult?
        parent.mutateActiveTableRows(for: tabId) { rows in
            let result = parent.rowOperationsManager.addNewRow(tableRows: &rows)
            addResult = result
            return result?.delta ?? .none
        }

        guard let result = addResult else { return }

        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(result.delta)
        selectAndEditInsertedRow(result.rowID, tabId: tabId)
    }

    func deleteSelectedRows(indices: Set<Int>) {
        guard !parent.safeModeLevel.blocksAllWrites,
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              tab.tableContext.isEditable,
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
        guard !parent.safeModeLevel.blocksAllWrites,
              let (tab, tabIndex) = parent.tabManager.selectedTabAndIndex,
              tab.tableContext.isEditable,
              tab.tableContext.tableName != nil else { return }

        let tabId = tab.id
        let tableRows = parent.tabSessionRegistry.tableRows(for: tabId)
        guard tableRows.hasAuthoritativeSchema,
              let storageIndex = DisplayRowMapping.rowIndex(
                  forDisplay: index, displayIDs: parent.activeGridDisplayIDs, in: tableRows
              ) else { return }

        parent.dataTabDelegate?.tableViewCoordinator?.commitActiveCellEdit()

        var dupResult: RowOperationsManager.AddNewRowResult?
        parent.mutateActiveTableRows(for: tabId) { rows in
            let result = parent.rowOperationsManager.duplicateRow(
                sourceRowIndex: storageIndex,
                tableRows: &rows
            )
            dupResult = result
            return result?.delta ?? .none
        }

        guard let result = dupResult else { return }

        parent.tabManager.mutate(at: tabIndex) { $0.hasUserInteraction = true }
        parent.dataTabDelegate?.tableViewCoordinator?.applyDelta(result.delta)
        selectAndEditInsertedRow(result.rowID, tabId: tabId)
    }

    private func selectAndEditInsertedRow(_ rowID: RowID, tabId: UUID) {
        guard selectionPointsTheGrid,
              let displayIndex = displayIndex(of: rowID, tabId: tabId) else { return }
        parent.selectionState.indices = [displayIndex]
        parent.dataTabDelegate?.tableViewCoordinator?.beginEditingFirstEditableColumn(displayRow: displayIndex)
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
