//
//  MainContentCoordinator+ColumnLayout.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func saveColumnLayoutForTable() {
        guard let index = tabManager.selectedTabIndex else { return }
        let tab = tabManager.tabs[index]
        guard tab.tabType == .table, let tableName = tab.tableName, !tableName.isEmpty else { return }

        ColumnLayoutStorage.shared.save(tab.columnLayout, for: tableName, connectionId: connectionId)
        columnVisibilityManager.saveLastHiddenColumns(for: tableName, connectionId: connectionId)
    }

    func restoreColumnLayoutForTable(_ tableName: String) {
        guard let index = tabManager.selectedTabIndex else { return }

        if let savedLayout = ColumnLayoutStorage.shared.load(for: tableName, connectionId: connectionId) {
            tabManager.tabs[index].columnLayout.columnWidths = savedLayout.columnWidths
            tabManager.tabs[index].columnLayout.columnOrder = savedLayout.columnOrder
        }
        restoreLastHiddenColumnsForTable(tableName)
    }
}
