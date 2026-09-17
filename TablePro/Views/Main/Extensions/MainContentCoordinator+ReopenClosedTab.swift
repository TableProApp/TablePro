//
//  MainContentCoordinator+ReopenClosedTab.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// Takes a tab rebuilt from the recently closed history into this connection's list, on the
    /// terms a restored session brings its tabs back: a table tab gets its hidden columns and
    /// filters before it loads, rather than a first page drawn without them.
    internal func adoptRestoredTab(_ tab: QueryTab) {
        tabManager.adoptTab(tab, claimFocus: tab.tabType == .query)
        guard tab.tabType == .table, let tableName = tab.tableContext.tableName else { return }
        restoreLastHiddenColumnsForTable()
        restoreFiltersForTable(tableName)
        lazyLoadCurrentTabIfNeeded(trigger: .restore)
    }
}
