//
//  MainContentCoordinator+ColumnVisibility.swift
//  TablePro
//

import Foundation

struct ColumnLayoutClearTarget: Equatable {
    let tabId: UUID
    let tableKey: ColumnLayoutTableKey
}

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

    func restoreLastHiddenColumnsForTable() {
        guard let tab = tabManager.selectedTab, let key = columnLayoutTableKey(for: tab) else { return }
        let restored = FileColumnLayoutPersister.shared.loadHiddenColumns(for: key)
        mutateSelectedTabHiddenColumns(persist: false) { $0 = restored }
    }

    func applyColumnGeometry(from geometry: ColumnLayoutState, toTabId tabId: UUID) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabManager.mutate(at: index) { $0.columnLayout.applyGeometry(from: geometry) }
    }

    func clearColumnLayoutForSelectedTable() {
        guard let target = selectedColumnLayoutClearTarget() else { return }
        clearColumnLayout(target)
    }

    func selectedColumnLayoutClearTarget() -> ColumnLayoutClearTarget? {
        guard let tab = tabManager.selectedTab,
              let tableKey = columnLayoutTableKey(for: tab) else { return nil }
        return ColumnLayoutClearTarget(tabId: tab.id, tableKey: tableKey)
    }

    func clearColumnLayout(_ target: ColumnLayoutClearTarget) {
        if tabManager.selectedTabId == target.tabId,
           dataTabDelegate?.tableViewCoordinator?.columnLayoutKey == target.tableKey {
            dataTabDelegate?.tableViewCoordinator?.resetColumnWidthOwnership()
        }
        FileColumnLayoutPersister.shared.clearGeometry(for: target.tableKey)
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == target.tabId }),
              columnLayoutTableKey(for: tabManager.tabs[index]) == target.tableKey else { return }
        tabManager.mutate(at: index) { tab in
            tab.columnLayout.resetGeometry()
        }
    }

    func resetColumns() {
        guard let index = tabManager.selectedTabIndex else { return }
        dataTabDelegate?.tableViewCoordinator?.resetColumnWidthOwnership()
        let tab = tabManager.tabs[index]
        if let key = columnLayoutTableKey(for: tab) {
            FileColumnLayoutPersister.shared.clear(for: key)
        }
        tabManager.mutate(at: index) { $0.columnLayout = ColumnLayoutState() }
        requeryWithColumnScope(debounced: false)
    }

    private func columnLayoutTableKey(for tab: QueryTab) -> ColumnLayoutTableKey? {
        guard let tableName = tab.tableContext.tableName, !tableName.isEmpty else { return nil }
        return ColumnLayoutTableKey(
            connectionId: connectionId,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName,
            tableName: tableName
        )
    }

    func rebuildSelectedTableQueryForHiddenColumnsIfNeeded() async {
        guard let tab = tabManager.selectedTab,
              !tab.columnLayout.hiddenColumns.isEmpty else { return }

        await rebuildSelectedTableColumnScopedQuery()
    }

    private func persistTabHiddenColumns(_ tab: QueryTab) {
        guard tab.tabType == .table, let key = columnLayoutTableKey(for: tab) else { return }
        FileColumnLayoutPersister.shared.saveHiddenColumns(tab.columnLayout.hiddenColumns, for: key)
    }

    private func mutateSelectedTabHiddenColumns(persist: Bool = true, _ mutate: (inout Set<String>) -> Void) {
        guard let index = tabManager.selectedTabIndex else { return }
        var hidden = tabManager.tabs[index].columnLayout.hiddenColumns
        mutate(&hidden)
        tabManager.mutate(at: index) { $0.columnLayout.hiddenColumns = hidden }
        if persist {
            persistTabHiddenColumns(tabManager.tabs[index])
        }
    }
}
