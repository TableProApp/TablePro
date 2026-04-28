//
//  MainContentCoordinator+TableRowsMutation.swift
//  TablePro
//
//  Single mutation surface for the active ResultSet's TableRows. Routes every
//  mutation through the store, then syncs the active ResultSet so reads via
//  `tab.display.activeResultSet?.tableRows` stay coherent with store state.
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
        syncActiveResultSet(for: tabId)
        return delta
    }

    func setActiveTableRows(_ tableRows: TableRows, for tabId: UUID) {
        tableRowsStore.setTableRows(tableRows, for: tabId)
        syncActiveResultSet(for: tabId)
    }

    func switchActiveResultSet(to resultSetId: UUID?, in tabId: UUID) {
        guard let tabIdx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabManager.tabs[tabIdx].display.activeResultSetId = resultSetId
        if let rs = tabManager.tabs[tabIdx].display.activeResultSet {
            tableRowsStore.setTableRows(rs.tableRows, for: tabId)
        }
    }

    private func syncActiveResultSet(for tabId: UUID) {
        guard let tabIdx = tabManager.tabs.firstIndex(where: { $0.id == tabId }),
              let activeRS = tabManager.tabs[tabIdx].display.activeResultSet else { return }
        activeRS.tableRows = tableRowsStore.tableRows(for: tabId)
    }
}
