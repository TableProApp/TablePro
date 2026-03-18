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
        if let tabIndex = tabManager.selectedTabIndex,
           tabManager.tabs[tabIndex].showStructure {
            return
        }

        let hasEditedCells = changeManager.hasChanges

        if hasEditedCells || hasPendingTableOps {
            Task { @MainActor in
                let window = NSApp.keyWindow
                let confirmed = await confirmDiscardChanges(action: .refresh, window: window)
                if confirmed {
                    onDiscard()
                    changeManager.clearChanges()
                    // Only execute query if we're in a table tab
                    // Query tabs should not auto-execute on refresh (use Cmd+Enter to execute)
                    if let tabIndex = tabManager.selectedTabIndex,
                       tabManager.tabs[tabIndex].tabType == .table {
                        currentQueryTask?.cancel()
                        rebuildTableQuery(at: tabIndex)
                        runQuery()
                    }
                }
            }
        } else {
            // Only execute query if we're in a table tab
            // Query tabs should not auto-execute on refresh (use Cmd+Enter to execute)
            if let tabIndex = tabManager.selectedTabIndex,
               tabManager.tabs[tabIndex].tabType == .table {
                currentQueryTask?.cancel()
                rebuildTableQuery(at: tabIndex)
                runQuery()
            }
        }
    }
}
