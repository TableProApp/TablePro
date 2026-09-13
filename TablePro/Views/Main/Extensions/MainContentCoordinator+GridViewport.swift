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

    func isGridMounted(forTab tabId: UUID) -> Bool {
        guard tabManager.selectedTabId == tabId,
              let tab = tabManager.selectedTab,
              tab.tabType == .table,
              tab.display.resultsViewMode == .data else { return false }
        return dataTabDelegate?.tableViewCoordinator != nil
    }

    func viewportKeyColumns(forTab tabId: UUID) -> [String] {
        tabManager.tabs.first(where: { $0.id == tabId })?.tableContext.primaryKeyColumns ?? []
    }

    func viewportSnapshot(
        forTab tabId: UUID,
        intent: GridReloadIntent,
        keyColumns: [String]
    ) -> GridViewportSnapshot {
        guard intent == .keepPlace,
              let tableRows = tabSessionRegistry.existingTableRows(for: tabId),
              !tableRows.rows.isEmpty,
              let sample = dataTabDelegate?.tableViewCoordinator?.viewportSample() else { return .top }

        return GridViewportResolver.snapshot(
            of: tableRows,
            displayIDs: displayIDs(forTab: tabId),
            firstVisibleDisplayRow: sample.firstVisibleRow,
            firstVisibleOffset: sample.offset,
            keyColumns: keyColumns,
            isCellModified: { [changeManager] rowID, column in
                changeManager.isCellModified(rowID: rowID, columnIndex: column)
            }
        )
    }
}
