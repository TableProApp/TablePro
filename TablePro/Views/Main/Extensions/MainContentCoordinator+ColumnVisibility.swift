//
//  MainContentCoordinator+ColumnVisibility.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    var selectedTabHiddenColumns: Set<String> {
        guard let tab = tabManager.selectedTab else { return [] }
        return tab.columnLayout.hiddenColumns
    }

    func hideColumn(_ columnName: String) {
        mutateSelectedTabHiddenColumns { $0.insert(columnName) }
    }

    func showColumn(_ columnName: String) {
        mutateSelectedTabHiddenColumns { $0.remove(columnName) }
    }

    func toggleColumnVisibility(_ columnName: String) {
        mutateSelectedTabHiddenColumns { hidden in
            if hidden.contains(columnName) {
                hidden.remove(columnName)
            } else {
                hidden.insert(columnName)
            }
        }
    }

    func showAllColumns() {
        mutateSelectedTabHiddenColumns { $0.removeAll() }
    }

    func hideAllColumns(_ columns: [String]) {
        mutateSelectedTabHiddenColumns { $0 = Set(columns) }
    }

    func pruneHiddenColumns(currentColumns: [String]) {
        let currentSet = Set(currentColumns)
        mutateSelectedTabHiddenColumns { $0 = $0.intersection(currentSet) }
    }

    func restoreLastHiddenColumnsForTable(_ tableName: String) {
        let restored = ColumnVisibilityPersistence.loadHiddenColumns(
            for: tableName,
            connectionId: connectionId
        )
        mutateSelectedTabHiddenColumns { $0 = restored }
    }

    func saveColumnVisibilityForActiveTable() {
        guard let tab = tabManager.selectedTab else { return }
        persistTabHiddenColumns(tab)
    }

    func persistOutgoingTabHiddenColumns(oldIndex: Int) {
        guard tabManager.tabs.indices.contains(oldIndex) else { return }
        persistTabHiddenColumns(tabManager.tabs[oldIndex])
    }

    private func persistTabHiddenColumns(_ tab: QueryTab) {
        guard tab.tabType == .table,
              let tableName = tab.tableContext.tableName,
              !tableName.isEmpty else { return }
        ColumnVisibilityPersistence.saveHiddenColumns(
            tab.columnLayout.hiddenColumns,
            for: tableName,
            connectionId: connectionId
        )
    }

    private func mutateSelectedTabHiddenColumns(_ mutate: (inout Set<String>) -> Void) {
        guard let index = tabManager.selectedTabIndex else { return }
        var hidden = tabManager.tabs[index].columnLayout.hiddenColumns
        mutate(&hidden)
        tabManager.mutate(at: index) { $0.columnLayout.hiddenColumns = hidden }
        let tabId = tabManager.tabs[index].id
        tabSessionRegistry.session(for: tabId)?.columnLayout.hiddenColumns = hidden
    }
}
