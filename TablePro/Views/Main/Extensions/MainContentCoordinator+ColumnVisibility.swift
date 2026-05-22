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
        requeryWithColumnScope(debounced: true)
    }

    func showColumn(_ columnName: String) {
        mutateSelectedTabHiddenColumns { $0.remove(columnName) }
        requeryWithColumnScope(debounced: true)
    }

    func toggleColumnVisibility(_ columnName: String) {
        mutateSelectedTabHiddenColumns { hidden in
            if hidden.contains(columnName) {
                hidden.remove(columnName)
            } else {
                hidden.insert(columnName)
            }
        }
        requeryWithColumnScope(debounced: true)
    }

    func showAllColumns() {
        mutateSelectedTabHiddenColumns { $0.removeAll() }
        requeryWithColumnScope(debounced: true)
    }

    func hideAllColumns(_ columns: [String]) {
        mutateSelectedTabHiddenColumns { $0 = Set(columns) }
        requeryWithColumnScope(debounced: true)
    }

    func pruneHiddenColumns(currentColumns: [String]) {
        let current = selectedTabHiddenColumns
        let pruned = ColumnFetchScope.prunedHiddenColumns(
            current,
            schemaColumns: selectedTabSchemaColumns(),
            resultColumns: currentColumns
        )
        guard pruned != current else { return }
        mutateSelectedTabHiddenColumns { $0 = pruned }
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
