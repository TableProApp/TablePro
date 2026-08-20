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

    func switchActiveResultSet(to resultSetId: UUID?, in tabId: UUID) {
        guard let tabIdx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        if let outgoing = tabManager.tabs[tabIdx].display.activeResultSet {
            outgoing.tableRows = tabSessionRegistry.tableRows(for: tabId)
        }
        tabManager.mutate(at: tabIdx) { $0.display.activeResultSetId = resultSetId }
        if let incoming = tabManager.tabs[tabIdx].display.activeResultSet {
            tabSessionRegistry.setTableRows(incoming.tableRows, for: tabId)
            resetSelectionForNewResult(tabId: tabId)
            syncLoadMoreState(from: incoming, at: tabIdx)
            notifyFullReplaceIfActive(tabId: tabId)
        }
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
    }
}
