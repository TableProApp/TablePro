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
        tableRowsStore.updateTableRows(for: tabId) { rows in
            delta = mutate(&rows)
        }
        return delta
    }

    func setActiveTableRows(_ tableRows: TableRows, for tabId: UUID) {
        tableRowsStore.setTableRows(tableRows, for: tabId)
        notifyFullReplaceIfActive(tabId: tabId)
    }

    func switchActiveResultSet(to resultSetId: UUID?, in tabId: UUID) {
        guard let tabIdx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        if let outgoing = tabManager.tabs[tabIdx].display.activeResultSet {
            outgoing.tableRows = tableRowsStore.tableRows(for: tabId)
        }
        tabManager.tabs[tabIdx].display.activeResultSetId = resultSetId
        if let incoming = tabManager.tabs[tabIdx].display.activeResultSet {
            tableRowsStore.setTableRows(incoming.tableRows, for: tabId)
            notifyFullReplaceIfActive(tabId: tabId)
        }
    }

    private func notifyFullReplaceIfActive(tabId: UUID) {
        guard let idx = tabManager.selectedTabIndex,
              idx < tabManager.tabs.count,
              tabManager.tabs[idx].id == tabId else { return }
        dataTabDelegate?.tableViewCoordinator?.applyFullReplace()
    }
}
