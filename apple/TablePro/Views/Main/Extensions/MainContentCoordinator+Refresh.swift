//
//  MainContentCoordinator+Refresh.swift
//  TablePro
//
//  Refresh handling operations for MainContentCoordinator
//

import AppKit
import Combine
import Foundation
import TableProSQLGrammar

extension MainContentCoordinator {
    // MARK: - Refresh Handling

    private static let refreshCoalesceInterval: Duration = .milliseconds(250)

    func requestRefresh(hasPendingTableOps: Bool, onDiscard: @escaping () -> Void) {
        if refreshCoalesceTask == nil {
            fireRefresh(hasPendingTableOps: hasPendingTableOps, onDiscard: onDiscard)
        } else {
            refreshPendingTrailing = true
        }
        refreshCoalesceTask?.cancel()
        refreshCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshCoalesceInterval)
            guard let self, !Task.isCancelled else { return }
            self.refreshCoalesceTask = nil
            if self.refreshPendingTrailing {
                self.refreshPendingTrailing = false
                self.fireRefresh(hasPendingTableOps: hasPendingTableOps, onDiscard: onDiscard)
            }
        }
    }

    private func fireRefresh(hasPendingTableOps: Bool, onDiscard: @escaping () -> Void) {
        handleRefresh(hasPendingTableOps: hasPendingTableOps, onDiscard: onDiscard)
        services.catalogChangeService.record(.changed(CatalogChange(connectionId: connectionId, kinds: .everything)))
    }

    func handleRefresh(
        hasPendingTableOps: Bool,
        onDiscard: @escaping () -> Void
    ) {
        guard let (tab, _) = tabManager.selectedTabAndIndex else { return }
        switch tab.tabType {
        case .versionHistory, .tableListing, .serverDashboard, .insights, .tableHealth, .objectSource:
            AppEvents.shared.tabRefreshRequested.send(tab.id)
            return
        case .erDiagram:
            if let diagram = erDiagramModels[tab.id] {
                Task { await diagram.refresh() }
            }
            return
        case .usersRoles:
            usersRolesActions?.refresh()
            return
        case .query, .table, .createTable, .routineDebug:
            break
        }
        if tab.display.resultsViewMode == .structure {
            activeStructureSession?.refresh()
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

        commitActiveGridEdit()
        guard changeManager.hasChanges || hasPendingTableOps else {
            reloadTableTab(at: tabIndex)
            return
        }

        Task {
            let confirmed = await confirmDiscardChanges(action: .refresh, window: contentWindow)
            guard confirmed else { return }
            onDiscard()
            rowEditingCoordinator.restoreRowBufferToOriginals()
            changeManager.clearChangesAndUndoHistory()
            guard let (tab, tabIndex) = tabManager.selectedTabAndIndex,
                  tab.tabType == .table else { return }
            reloadTableTab(at: tabIndex)
        }
    }

    func reloadTableTab(at tabIndex: Int) {
        stopExecution(for: tabManager.tabs[tabIndex].id)
        // A refresh retires the earlier exact count, else the automatic count refuses to re-derive rather than downgrade it to an estimate.
        tabManager.mutate(at: tabIndex) { $0.pagination.retireDerivedRowCount() }
        rebuildTableQuery(at: tabIndex)
        runQuery(viewport: .keepPlace)
    }
}
