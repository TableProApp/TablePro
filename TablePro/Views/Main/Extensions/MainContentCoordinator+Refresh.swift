//
//  MainContentCoordinator+Refresh.swift
//  TablePro
//
//  Refresh handling operations for MainContentCoordinator
//

import AppKit
import Foundation

extension MainContentCoordinator {
    // MARK: - Refresh Handling

    func handleRefresh(
        hasPendingTableOps: Bool,
        onDiscard: @escaping () -> Void
    ) {
        // If showing structure view, let it handle refresh notifications
        if let (tab, _) = tabManager.selectedTabAndIndex,
           tab.display.resultsViewMode == .structure {
            return
        }

        let hasEditedCells = changeManager.hasChanges

        if hasEditedCells || hasPendingTableOps {
            Task {
                let window = NSApp.keyWindow
                let confirmed = await confirmDiscardChanges(action: .refresh, window: window)
                if confirmed {
                    onDiscard()
                    changeManager.clearChangesAndUndoHistory()
                    // Query tabs should not auto-execute on refresh (use Cmd+Enter to execute)
                    if let (tab, tabIndex) = tabManager.selectedTabAndIndex,
                       tab.tabType == .table {
                        currentQueryTask?.cancel()
                        rebuildTableQuery(at: tabIndex)
                        runQuery()
                    }
                }
            }
        } else {
            if let (tab, tabIndex) = tabManager.selectedTabAndIndex,
               tab.tabType == .table {
                currentQueryTask?.cancel()
                rebuildTableQuery(at: tabIndex)
                runQuery()
            }
        }
    }
}
