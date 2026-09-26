//
//  MainContentCoordinator+Refresh.swift
//  TablePro
//
//  Refresh handling operations for MainContentCoordinator
//

import AppKit
import Combine
import Foundation

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
        if tab.tabType == .versionHistory {
            AppEvents.shared.versionHistoryRefreshRequested.send(tab.id)
            return
        }
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

        dataTabDelegate?.tableViewCoordinator?.commitActiveCellEdit()
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

    /// Reloads the selected tab's rows while its Structure pane is in front, so Data shows the table
    /// as it now is. Rows holding the user's edits are kept, and a tab that never loaded its rows has
    /// none to reload.
    func reloadRowsBehindStructure(hasPendingTableOps: Bool) {
        guard let (tab, tabIndex) = tabManager.selectedTabAndIndex,
              tab.tabType == .table,
              tab.display.resultsViewMode == .structure,
              tab.execution.lastExecutedAt != nil,
              !changeManager.hasChanges,
              !tab.pendingChanges.hasChanges,
              !hasPendingTableOps
        else { return }
        reloadTableTab(at: tabIndex)
    }

    /// Fetches the structure again where no one is editing it: now for the one on screen, on its next
    /// mount for the rest. A structure holding staged edits keeps them and the baseline they were
    /// staged against, because a fetch adopts a new baseline and clears them without asking.
    func refreshStructure(ofTabs tabs: [QueryTab]) {
        let selectedId = tabManager.selectedTabId
        for tab in tabs {
            guard let session = structureSessions[tab.id], !session.changeManager.hasChanges else { continue }
            if tab.id == selectedId, tab.display.resultsViewMode == .structure, let refresh = structureActions?.refresh {
                refresh()
            } else {
                session.markStructureStale()
            }
        }
    }

    /// The columns a column-scoped query is built from describe the table before the change, and a
    /// reload builds its select list from them before it fetches anything, so a dropped column would
    /// stay in it. The reload's own fetch stores the new set.
    func forgetSchemaColumns(of change: DatabaseObjectChange, tabs: [QueryTab]) {
        schemaColumns.remove(schemaColumnsKey(change.name, scope: change.scope))
        for tab in tabs {
            schemaColumns.remove(schemaColumnsKey(change.name, scope: scope(for: tab)))
        }
    }

    private func reloadTableTab(at tabIndex: Int) {
        stopExecution(for: tabManager.tabs[tabIndex].id)
        /// A refresh asks for the table as it is now, so the exact count the user requested earlier
        /// describes a table that may have moved on. Retiring it here is what lets the automatic
        /// count re-derive a total, which it otherwise refuses to do rather than downgrade an exact
        /// count to an estimate.
        tabManager.mutate(at: tabIndex) { $0.pagination.retireDerivedRowCount() }
        rebuildTableQuery(at: tabIndex)
        runQuery(viewport: .keepPlace)
    }
}
