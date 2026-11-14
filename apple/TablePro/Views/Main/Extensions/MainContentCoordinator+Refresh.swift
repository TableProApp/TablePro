//
//  MainContentCoordinator+Refresh.swift
//  TablePro
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
        let requestedTabId = tabManager.selectedTabId
        refreshCoalesceTask?.cancel()
        refreshCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshCoalesceInterval)
            guard let self, !Task.isCancelled else { return }
            self.refreshCoalesceTask = nil
            if self.refreshPendingTrailing {
                self.refreshPendingTrailing = false
                // A tab selected since the request is not the one it asked to refresh.
                guard self.tabManager.selectedTabId == requestedTabId else { return }
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
        case .versionHistory, .tableListing, .serverDashboard, .insights, .objectSource:
            AppEvents.shared.tabRefreshRequested.send(tab.id)
            return
        case .tableHealth:
            if let model = tableHealthModels[tab.id] {
                Task { await model.refresh() }
            }
            return
        case .erDiagram:
            if let diagram = erDiagramModels[tab.id] {
                Task { await diagram.refresh() }
            }
            return
        case .usersRoles:
            usersRolesActions?.refresh()
            return
        case .query, .table, .createTable, .routineDebug, .liveMessages:
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
        guard let (tab, _) = tabManager.selectedTabAndIndex,
              tab.tabType == .table,
              tab.display.resultsViewMode != .structure else { return }

        let tabId = tab.id
        commitActiveGridEdit()
        let manager = changeManager(forTab: tabId)
        guard manager.hasChanges || hasPendingTableOps else {
            reloadTableTab(tabId)
            return
        }

        Task {
            let confirmed = await confirmDiscardChanges(action: .refresh, window: contentWindow)
            guard confirmed, tabManager.tabs.contains(where: { $0.id == tabId }) else { return }
            onDiscard()
            rowEditingCoordinator.restoreRowBufferToOriginals(forTab: tabId)
            manager.clearChangesAndUndoHistory()
            guard tabManager.tabs.first(where: { $0.id == tabId })?.tabType == .table else { return }
            reloadTableTab(tabId)
        }
    }

    func reloadTableTab(_ tabId: UUID) {
        guard tabManager.tabs.contains(where: { $0.id == tabId }) else { return }
        stopExecution(for: tabId)
        // A refresh retires the earlier exact count, else the automatic count refuses to re-derive rather than downgrade it to an estimate.
        tabManager.mutate(tabId: tabId) { $0.pagination.retireDerivedRowCount() }
        rebuildTableQuery(forTab: tabId)
        runQuery(onTab: tabId, viewport: .keepPlace)
        // The next tick counts from this load settling, not from the last one.
        if tabManager.selectedTabId == tabId {
            restartAutoRefresh()
        }
    }
}
