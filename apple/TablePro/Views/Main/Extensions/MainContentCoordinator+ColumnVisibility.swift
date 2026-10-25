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
        changeColumnScope { $0.insert(columnName) }
    }

    func showColumn(_ columnName: String) {
        changeColumnScope { $0.remove(columnName) }
    }

    func toggleColumnVisibility(_ columnName: String) {
        changeColumnScope { hidden in
            if hidden.contains(columnName) {
                hidden.remove(columnName)
            } else {
                hidden.insert(columnName)
            }
        }
    }

    func showAllColumns() {
        changeColumnScope { $0.removeAll() }
    }

    func hideAllColumns(_ columns: [String]) {
        changeColumnScope { $0 = Set(columns) }
    }

    // Confirms like sort, pagination and the WHERE filter: re-running with a new column list drops unsaved edits (#2667).
    private func changeColumnScope(_ mutate: @escaping (inout Set<String>) -> Void) {
        confirmDiscardRestoringRowsIfNeeded(action: .columnVisibility) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.mutateSelectedTabHiddenColumns(mutate)
            self.requeryWithColumnScope(debounced: true)
        }
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
        if let entry = dataGridEntries[target.tabId],
           let tab = tabManager.tabs.first(where: { $0.id == target.tabId }),
           columnLayoutTableKey(for: tab) == target.tableKey {
            entry.store.discardPendingLayout()
            entry.model.updateColumnLayout { $0.resetGeometry() }
        }
        FileColumnLayoutPersister.shared.clearGeometry(for: target.tableKey)
        guard let index = tabManager.tabs.firstIndex(where: { $0.id == target.tabId }),
              columnLayoutTableKey(for: tabManager.tabs[index]) == target.tableKey else { return }
        tabManager.mutate(at: index) { tab in
            tab.columnLayout.resetGeometry()
        }
    }

    // Clearing the hidden set re-queries, so reset confirms too; declining keeps the width reset, since widths cannot void edits.
    func resetColumns() {
        confirmDiscardRestoringRowsIfNeeded(action: .columnVisibility) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.applyColumnReset()
        }
    }

    private func applyColumnReset() {
        guard let index = tabManager.selectedTabIndex else { return }
        let tab = tabManager.tabs[index]
        if let entry = dataGridEntries[tab.id] {
            entry.store.discardPendingLayout()
            entry.model.updateColumnLayout { $0.resetGeometry() }
        }
        if let key = columnLayoutTableKey(for: tab) {
            FileColumnLayoutPersister.shared.clear(for: key)
        }
        tabManager.mutate(at: index) { $0.columnLayout = ColumnLayoutState() }
        requeryWithColumnScope(debounced: false)
    }

    // A temporary table's layout is not kept: the key would be the permanent table's of the same name.
    func columnLayoutTableKey(for tab: QueryTab) -> ColumnLayoutTableKey? {
        guard !tab.tableContext.isTemporary, let tableName = tab.tableContext.tableName, !tableName.isEmpty else {
            return nil
        }
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
        guard hidden != tabManager.tabs[index].columnLayout.hiddenColumns else { return }
        // Through the model first, which rebuilds its columns and keeps the selection by column identity.
        existingGridModel(forTab: tabManager.tabs[index].id)?.updateColumnLayout { $0.hiddenColumns = hidden }
        if tabManager.tabs[index].columnLayout.hiddenColumns != hidden {
            tabManager.mutate(at: index) { $0.columnLayout.hiddenColumns = hidden }
        }
        if persist {
            persistTabHiddenColumns(tabManager.tabs[index])
        }
        consumePendingColumnJump(forTab: tabManager.tabs[index].id, contentReplaced: false)
    }
}
