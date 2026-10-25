//
//  MainContentCoordinator+GridViewport.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func restoredRowAnchor(forTab tabId: UUID) -> [String: String]? {
        tabManager.tabs.first(where: { $0.id == tabId })?.restoredRowAnchor
    }

    func clearRestoredRowAnchor(forTab tabId: UUID) {
        guard restoredRowAnchor(forTab: tabId) != nil else { return }
        tabManager.mutate(tabId: tabId) { $0.restoredRowAnchor = nil }
    }

    // A query tab's grid stays where AppKit leaves it after a run; only a re-read of its own result keeps place and selection.
    func isGridMounted(forTab tabId: UUID, acceptsQueryTab: Bool = false) -> Bool {
        guard tabManager.selectedTabId == tabId,
              let tab = tabManager.selectedTab,
              tab.tabType == .table || (acceptsQueryTab && tab.tabType == .query),
              tab.display.resultsViewMode == .data else { return false }
        return existingGridModel(forTab: tabId)?.isMounted == true
    }

    func viewportKeyColumns(forTab tabId: UUID) -> [String] {
        tabManager.tabs.first(where: { $0.id == tabId })?.tableContext.primaryKeyColumns ?? []
    }

    func viewportSnapshot(
        forTab tabId: UUID,
        intent: GridReloadIntent,
        keepsSelection: Bool = false,
        keyColumns: [String]
    ) -> GridViewportSnapshot {
        guard intent == .keepPlace || keepsSelection,
              let tableRows = tabSessionRegistry.existingTableRows(for: tabId),
              !tableRows.rows.isEmpty else { return .top }
        let model = existingGridModel(forTab: tabId)
        let sample = intent == .keepPlace ? viewportSample(of: model) : nil
        guard sample != nil || keepsSelection else { return .top }

        let snapshot = GridViewportResolver.snapshot(
            of: tableRows,
            displayIDs: model?.displayedRowIDs,
            firstVisibleDisplayRow: sample?.row ?? 0,
            firstVisibleOffset: sample?.offset ?? 0,
            selectedDisplayRows: keepsSelection ? Array(model?.selection.affectedRows ?? IndexSet()) : [],
            keyColumns: keyColumns,
            isCellModified: { [changeManager] rowID, column in
                changeManager.isCellModified(rowID: rowID, columnIndex: column)
            }
        )
        return sample == nil ? snapshot.selectionOnly : snapshot
    }

    // The mounted grid's first visible row, else the anchor the grid saved when it was last unmounted.
    private func viewportSample(of model: DataGridModel?) -> (row: Int, offset: CGFloat)? {
        guard let model else { return nil }
        if let live = model.viewportSample() { return live }
        guard let anchor = model.store.viewportAnchor,
              let rowID = anchor.firstVisibleRow,
              let row = model.displayIndex(of: rowID) else { return nil }
        return (row, anchor.firstVisibleOffset)
    }
}
