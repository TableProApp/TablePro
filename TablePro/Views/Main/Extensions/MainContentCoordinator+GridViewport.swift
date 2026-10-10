//
//  MainContentCoordinator+GridViewport.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func takeViewportPlacement(forTab tabId: UUID) -> GridViewportPlacement? {
        tabSessionRegistry.takeViewportPlacement(for: tabId)
    }

    func restoredRowAnchor(forTab tabId: UUID) -> [String: String]? {
        tabManager.tabs.first(where: { $0.id == tabId })?.restoredRowAnchor
    }

    func clearRestoredRowAnchor(forTab tabId: UUID) {
        guard restoredRowAnchor(forTab: tabId) != nil else { return }
        tabManager.mutate(tabId: tabId) { $0.restoredRowAnchor = nil }
    }

    /// A query tab's grid stays where AppKit leaves it after a run; only a re-read of its own result
    /// asks to keep the place and the selection.
    func isGridMounted(forTab tabId: UUID, acceptsQueryTab: Bool = false) -> Bool {
        guard tabManager.selectedTabId == tabId,
              let tab = tabManager.selectedTab,
              tab.tabType == .table || (acceptsQueryTab && tab.tabType == .query),
              tab.display.resultsViewMode == .data else { return false }
        return dataTabDelegate?.tableViewCoordinator != nil
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
        let sample = intent == .keepPlace ? dataTabDelegate?.tableViewCoordinator?.viewportSample() : nil
        guard sample != nil || keepsSelection else { return .top }

        let snapshot = GridViewportResolver.snapshot(
            of: tableRows,
            displayIDs: displayIDs(forTab: tabId),
            firstVisibleDisplayRow: sample?.firstVisibleRow ?? 0,
            firstVisibleOffset: sample?.offset ?? 0,
            selectedDisplayRows: keepsSelection ? Array(selectionState.indices) : [],
            keyColumns: keyColumns,
            isCellModified: { [changeManager] rowID, column in
                changeManager.isCellModified(rowID: rowID, columnIndex: column)
            }
        )
        return sample == nil ? snapshot.selectionOnly : snapshot
    }
}
