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

    /// Every route that changes which columns are fetched, behind the same gate the WHERE filter
    /// uses on the very same `rebuildTableQuery` call.
    ///
    /// Hiding or showing a column re-runs the table's query with a different column list, so the
    /// rows are replaced and any unsaved edit goes with them. Sort, pagination and the WHERE filter
    /// all confirm before doing that; this was the one reload that did it without asking. (#2667)
    ///
    /// The set is mutated inside the approved work, so declining leaves the column list alone as
    /// well as the edits. Only the first change in a run prompts: confirming clears the changes, so
    /// every later toggle finds nothing to lose and passes straight through.
    private func changeColumnScope(_ mutate: @escaping (inout Set<String>) -> Void) {
        confirmDiscardChangesIfNeeded(action: .columnVisibility) { [weak self] confirmed in
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

    /// Reset clears the hidden set along with the widths, so it re-queries too and takes the same
    /// confirmation. The width half is not undone by declining, because nothing about a width can
    /// invalidate an edit; only the refetch can.
    func resetColumns() {
        confirmDiscardChangesIfNeeded(action: .columnVisibility) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.applyColumnReset()
        }
    }

    private func applyColumnReset() {
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
        let presentedRunChanged = hidden != tabManager.tabs[index].columnLayout.hiddenColumns
        tabManager.mutate(at: index) { tab in
            tab.columnLayout.hiddenColumns = hidden
            /// A stored cell rectangle is a set of display positions in the presented run, and
            /// hiding a column renumbers that run. Clamping cannot catch it: a position that is
            /// still in range now names a different column, so the rectangle would come back
            /// pointing at data the reader never selected. A mounted grid drops its own selection
            /// on the same event; this is that rule for a tab whose grid is not mounted. (#2667)
            guard presentedRunChanged, !tab.cellSelection.isEmpty else { return }
            tab.cellSelection = .empty
        }
        if persist {
            persistTabHiddenColumns(tabManager.tabs[index])
        }
    }
}
