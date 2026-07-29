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

    func restoreLastHiddenColumnsForTable() {
        guard let tab = tabManager.selectedTab, let key = columnLayoutTableKey(for: tab) else { return }
        let restored = FileColumnLayoutPersister.shared.loadHiddenColumns(for: key)
        mutateSelectedTabHiddenColumns(persist: false) { $0 = restored }
    }

    func applyColumnGeometry(from geometry: ColumnLayoutState, toTabId tabId: UUID) {
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabManager.mutate(at: index) { $0.columnLayout.applyGeometry(from: geometry) }
        tabSessionRegistry.session(for: tabId)?.columnLayout.applyGeometry(from: geometry)
    }

    func clearColumnLayoutForSelectedTable() {
        guard let tab = tabManager.selectedTab, let key = columnLayoutTableKey(for: tab) else { return }
        FileColumnLayoutPersister.shared.clear(for: key)
    }

    func resetColumns() {
        guard let index = tabManager.selectedTabIndex else { return }
        let tab = tabManager.tabs[index]
        if let key = columnLayoutTableKey(for: tab) {
            FileColumnLayoutPersister.shared.clear(for: key)
        }
        tabManager.mutate(at: index) { $0.columnLayout = ColumnLayoutState() }
        tabSessionRegistry.session(for: tab.id)?.columnLayout = ColumnLayoutState()
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
              !tab.columnLayout.hiddenColumns.isEmpty,
              tab.tableContext.databaseName.isEmpty || tab.tableContext.databaseName == activeDatabaseName else { return }

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
        let tabId = tabManager.tabs[index].id
        tabSessionRegistry.session(for: tabId)?.columnLayout.hiddenColumns = hidden
        if persist {
            persistTabHiddenColumns(tabManager.tabs[index])
        }
    }
}
