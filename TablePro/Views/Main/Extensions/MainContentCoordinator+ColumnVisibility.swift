//
//  MainContentCoordinator+ColumnVisibility.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// Save current hidden columns to the active tab's column layout
    func saveColumnVisibilityToTab() {
        guard let index = tabManager.selectedTabIndex else { return }
        tabManager.tabs[index].columnLayout.hiddenColumns = columnVisibilityManager.saveToColumnLayout()
    }

    /// Restore hidden columns from a tab's column layout
    func restoreColumnVisibilityFromTab(_ tab: QueryTab) {
        columnVisibilityManager.restoreFromColumnLayout(tab.columnLayout.hiddenColumns)
    }

    /// Load per-table hidden columns from UserDefaults when opening a table tab
    func restoreLastHiddenColumnsForTable(_ tableName: String) {
        columnVisibilityManager.restoreLastHiddenColumns(for: tableName, connectionId: connectionId)
    }

    /// Prune hidden columns that no longer exist in the current result set
    func pruneHiddenColumns(currentColumns: [String]) {
        columnVisibilityManager.pruneStaleColumns(currentColumns)
    }

    /// Hide a single column (routed through coordinator for centralized control)
    func hideColumn(_ columnName: String) {
        columnVisibilityManager.hideColumn(columnName)
    }
}
