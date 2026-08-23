//
//  MainContentCoordinator+TableRowsMutation.swift
//  TablePro
//
//  Single mutation surface for the active ResultSet's TableRows. Mutations
//  flow through the store; the per-ResultSet snapshot is only refreshed when
//  the user switches result sets (save outgoing, load incoming) so editing
//  one tab doesn't trigger an `@Observable` re-render of the whole editor.
//

import Foundation

extension MainContentCoordinator {
    @discardableResult
    func mutateActiveTableRows(
        for tabId: UUID,
        _ mutate: (inout TableRows) -> Delta
    ) -> Delta {
        var delta: Delta = .none
        tabSessionRegistry.updateTableRows(for: tabId) { rows in
            delta = mutate(&rows)
        }
        return delta
    }

    func setActiveTableRows(_ tableRows: TableRows, for tabId: UUID) {
        tabSessionRegistry.setTableRows(tableRows, for: tabId)
        resetSelectionForNewResult(tabId: tabId)
        notifyFullReplaceIfActive(tabId: tabId)
    }

    /// Switching result sets replaces what the grid shows and what an edit would be written to, so
    /// it takes the same unsaved-changes gate as sorting, paging and filtering. Without the gate a
    /// pending edit set outlives the switch and `handleColumnsChange` refuses to rebuild the change
    /// manager while it exists, which leaves the grid writing to the outgoing result's table.
    func switchActiveResultSet(to resultSetId: UUID?, in tabId: UUID) {
        guard let tabIdx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let wasActive = tabManager.tabs[tabIdx].display.activeResultSetId == resultSetId

        confirmDiscardChangesIfNeeded(action: .resultSwitch) { [weak self] confirmed in
            guard confirmed else { return }
            self?.applyResultSetSwitch(to: resultSetId, in: tabId)
            guard !wasActive else { return }
            self?.revealStatement(behind: resultSetId, in: tabId)
        }
    }

    /// Takes the reader to the statement a result came from, when they moved to a different result.
    ///
    /// This is the reverse of the run: a statement produces a result, so selecting the result says which statement to
    /// look at. It is only ever a response to the reader picking a result, which is what the HIG allows; nothing here
    /// runs on its own. Re-selecting the result already showing does nothing, because the reader is comparing pinned
    /// results rather than asking to be taken anywhere, and scrolling the editor under them would be an answer to a
    /// question they did not ask.
    ///
    /// The caret moves without taking first responder, so focus stays wherever the reader put it and the
    /// caret-statement band follows for free.
    private func revealStatement(behind resultSetId: UUID?, in tabId: UUID) {
        guard let tabIdx = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              tabManager.tabs[tabIdx].tabType == .query,
              let resultSetId,
              let anchor = tabManager.tabs[tabIdx].display.resultSets
                  .first(where: { $0.id == resultSetId })?.statementAnchor
        else { return }
        requestStatementJump(anchor, in: tabId)
    }

    /// The switch itself, for callers that have already decided the outgoing result is going away.
    func applyResultSetSwitch(to resultSetId: UUID?, in tabId: UUID) {
        guard let tabIdx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        flushBufferToActiveResult(tabId: tabId, pinnedOnly: false)
        tabManager.mutate(at: tabIdx) { $0.display.activeResultSetId = resultSetId }
        guard let incoming = tabManager.tabs[tabIdx].display.activeResultSet else { return }
        tabSessionRegistry.setTableRows(incoming.tableRows, for: tabId)
        resetSelectionForNewResult(tabId: tabId)
        syncLoadMoreState(from: incoming, at: tabIdx)
        adoptOrigin(of: incoming, at: tabIdx)
        notifyFullReplaceIfActive(tabId: tabId)
    }

    /// The shared row buffer holds whatever the active result is showing, and it is the only copy
    /// that page loads, Fetch All and cell edits write to. Handing it back before it is replaced is
    /// what keeps a result the user can return to from serving rows it never produced.
    func flushBufferToActiveResult(tabId: UUID, pinnedOnly: Bool) {
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              let active = tabManager.tabs[idx].display.activeResultSet,
              !pinnedOnly || active.isPinned
        else { return }
        active.tableRows = tabSessionRegistry.tableRows(for: tabId)
    }

    /// Re-points the shared buffer at whatever result just became active.
    ///
    /// A plan or an error result carries no rows, and leaving the previous result's rows in the
    /// buffer means the next flush hands them to it, after which it renders a data grid instead of
    /// its plan or its error.
    func seedBufferFromActiveResult(tabId: UUID) {
        guard let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let rows = tabManager.tabs[idx].display.activeResultSet?.tableRows ?? TableRows()
        tabSessionRegistry.setTableRows(rows, for: tabId)
    }

    /// A tab's table context describes its newest execution, so moving to another result has to
    /// move the context onto that result's own table. The change manager is rebuilt here rather
    /// than through the `schemaVersion` observer, because that observer refuses to run while
    /// unsaved edits exist and would leave the manager pointed at the outgoing table (#2243).
    private func adoptOrigin(of resultSet: ResultSet, at tabIdx: Int) {
        guard tabManager.tabs[tabIdx].tabType == .query else { return }
        let origin = resultSet.origin
        tabManager.mutate(at: tabIdx) { tab in
            tab.tableContext.tableName = origin?.tableName
            tab.tableContext.schemaName = origin?.schemaName
            tab.tableContext.primaryKeyColumns = origin?.primaryKeyColumns ?? []
            tab.tableContext.isEditable = origin?.isEditable ?? false
            tab.tableContext.isView = origin?.isView ?? false
            tab.schemaVersion += 1
        }
        let tab = tabManager.tabs[tabIdx]
        guard tab.id == tabManager.selectedTabId else { return }
        changeManager.configureForTable(
            tableName: tab.tableContext.tableName ?? "",
            schemaName: tab.tableContext.schemaName,
            columns: resultSet.resultColumns,
            primaryKeyColumns: tab.tableContext.primaryKeyColumns,
            databaseType: connection.type
        )
    }

    /// Row selection is a set of display positions into the result that produced it, so it
    /// means nothing once the rows are replaced wholesale. Leaving it in place points every
    /// consumer, the JSON view and the row inspector included, at rows that no longer exist.
    /// Incremental edits go through `mutateActiveTableRows` and keep their selection.
    ///
    /// The per-column value filter goes for the same reason: it stores the displayed strings the
    /// user picked out of the rows being replaced. Kept across a replacement it narrows an
    /// unrelated result to nothing, with only a header indicator to explain why.
    private func resetSelectionForNewResult(tabId: UUID) {
        clearValueFilter(forTab: tabId)
        tabManager.mutate(tabId: tabId) { tab in
            guard !tab.selectedRowIndices.isEmpty else { return }
            tab.selectedRowIndices = []
        }
        guard let idx = tabManager.selectedTabIndex,
              idx < tabManager.tabs.count,
              tabManager.tabs[idx].id == tabId else { return }
        dataTabDelegate?.tableViewCoordinator?.clearRowSelection()
        if !selectionState.indices.isEmpty {
            selectionState.indices = []
        }
    }

    private func syncLoadMoreState(from resultSet: ResultSet, at tabIdx: Int) {
        guard tabManager.tabs[tabIdx].tabType == .query else { return }
        tabManager.mutate(at: tabIdx) { tab in
            if resultSet.isTruncated {
                tab.pagination.hasMoreRows = true
                tab.pagination.isLoadingMore = false
            } else {
                tab.pagination.resetLoadMore()
            }
            tab.pagination.baseQueryForMore = resultSet.baseQuery
            tab.pagination.baseQueryParameterValues = resultSet.baseQueryParameterValues
        }
    }

    private func notifyFullReplaceIfActive(tabId: UUID) {
        guard let idx = tabManager.selectedTabIndex,
              idx < tabManager.tabs.count,
              tabManager.tabs[idx].id == tabId else { return }

        let tracer = TableLoadTracer.shared
        let token = tracer.applyingToken
        if let token {
            tracer.stage(
                .gridReloadBegin,
                token: token,
                detail: "rows=\(tabSessionRegistry.tableRows(for: tabId).rows.count)"
            )
        }
        dataTabDelegate?.tableViewCoordinator?.applyFullReplace()
        if let token { tracer.stage(.gridReloadEnd, token: token) }

        if pendingScrollToTopAfterReplace.remove(tabId) != nil {
            dataTabDelegate?.tableViewCoordinator?.scrollToTop()
        }

        /// Only once there are rows to find it in. The retarget that starts a navigation replaces
        /// the buffer with an empty one first, and consuming the anchor there would spend it before
        /// the rows it names have arrived.
        if !tabSessionRegistry.tableRows(for: tabId).rows.isEmpty,
           let anchor = pendingRowAnchors.removeValue(forKey: tabId) {
            dataTabDelegate?.tableViewCoordinator?.selectRow(matchingKey: anchor)
        }
    }
}
