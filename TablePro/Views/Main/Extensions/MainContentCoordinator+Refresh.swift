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
        guard let (tab, _) = tabManager.selectedTabAndIndex else { return }
        if tab.display.resultsViewMode == .structure {
            structureActions?.refresh?()
            return
        }
        reloadActiveTableData(hasPendingTableOps: hasPendingTableOps, onDiscard: onDiscard)
    }

    func reloadActiveTableData(
        hasPendingTableOps: Bool,
        onDiscard: @escaping () -> Void
    ) {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex,
              tab.tabType == .table,
              tab.display.resultsViewMode != .structure else { return }

        guard changeManager.hasChanges || hasPendingTableOps else {
            reloadTableTab(at: tabIndex)
            return
        }

        Task {
            let confirmed = await confirmDiscardChanges(action: .refresh, window: NSApp.keyWindow)
            guard confirmed else { return }
            onDiscard()
            changeManager.clearChangesAndUndoHistory()
            guard let (tab, tabIndex) = tabManager.selectedTabAndIndex,
                  tab.tabType == .table else { return }
            reloadTableTab(at: tabIndex)
        }
    }

    private func reloadTableTab(at tabIndex: Int) {
        cancelCurrentQuery()
        rebuildTableQuery(at: tabIndex)
        runQuery()
    }
}
