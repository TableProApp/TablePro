//
//  MainContentCoordinator+TabSwitch.swift
//  TablePro
//
//  Tab switching logic extracted from MainContentCoordinator
//  to keep the main class body within SwiftLint limits.
//

import Foundation
import os

extension MainContentCoordinator {
    func handleTabChange(
        from oldTabId: UUID?,
        to newTabId: UUID?,
        tabs: [QueryTab]
    ) {
        let start = Date()
        Self.lifecycleLogger.debug(
            "[switch] handleTabChange start from=\(oldTabId?.uuidString ?? "nil", privacy: .public) to=\(newTabId?.uuidString ?? "nil", privacy: .public) connId=\(self.connectionId, privacy: .public) tabsCount=\(self.tabManager.tabs.count)"
        )
        isHandlingTabSwitch = true
        defer {
            isHandlingTabSwitch = false
            Self.lifecycleLogger.debug(
                "[switch] handleTabChange done to=\(newTabId?.uuidString ?? "nil", privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
            )
        }

        let saveStart = Date()
        if let oldId = oldTabId,
           let oldIndex = tabManager.tabs.firstIndex(where: { $0.id == oldId })
        {
            if changeManager.hasChanges {
                tabManager.tabs[oldIndex].pendingChanges = changeManager.saveState()
            }
            if let tableName = tabManager.tabs[oldIndex].tableContext.tableName {
                FilterSettingsStorage.shared.saveLastFilters(
                    tabManager.tabs[oldIndex].filterState.appliedFilters,
                    for: tableName
                )
            }
            persistOutgoingTabHiddenColumns(oldIndex: oldIndex)
        }
        let saveMs = Int(Date().timeIntervalSince(saveStart) * 1_000)

        // Defer to the next run-loop tick so the synchronous switch path
        // stays cheap; the sort + budget calculation is non-trivial on
        // connections with many open tabs.
        if tabManager.tabs.count > 2 {
            let activeIds: Set<UUID> = Set([oldTabId, newTabId].compactMap { $0 })
            Task { @MainActor [weak self] in
                self?.evictInactiveTabs(excluding: activeIds)
            }
        }

        let restoreStart = Date()
        if let newId = newTabId,
           let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId }) {
            let newTab = tabManager.tabs[newIndex]
            let newRows = tabSessionRegistry.tableRows(for: newId)

            selectionState.indices = newTab.selectedRowIndices
            toolbarState.isTableTab = newTab.tabType == .table
            toolbarState.isResultsCollapsed = newTab.display.isResultsCollapsed

            let pendingState = newTab.pendingChanges
            if pendingState.hasChanges {
                changeManager.restoreState(from: pendingState, tableName: newTab.tableContext.tableName ?? "", databaseType: connection.type)
            } else {
                changeManager.configureForTable(
                    tableName: newTab.tableContext.tableName ?? "",
                    columns: newRows.columns,
                    primaryKeyColumns: newTab.tableContext.primaryKeyColumns.isEmpty
                        ? newRows.columns.prefix(1).map { $0 }
                        : newTab.tableContext.primaryKeyColumns,
                    databaseType: connection.type,
                    triggerReload: false
                )
            }

            let restoreMs = Int(Date().timeIntervalSince(restoreStart) * 1_000)
            Self.lifecycleLogger.debug(
                "[switch] handleTabChange phases: saveOutgoing=\(saveMs)ms restoreIncoming=\(restoreMs)ms"
            )

            if !newTab.tableContext.databaseName.isEmpty {
                let currentDatabase = activeDatabaseName

                if newTab.tableContext.databaseName != currentDatabase {
                    Self.lifecycleLogger.debug(
                        "[switch] handleTabChange triggering switchDatabase from=\(currentDatabase, privacy: .public) to=\(newTab.tableContext.databaseName, privacy: .public)"
                    )
                    changeManager.reloadVersion += 1
                    Task {
                        await switchDatabase(to: newTab.tableContext.databaseName)
                    }
                    return  // switchDatabase will re-execute the query
                }
            }

            changeManager.reloadVersion += 1
        } else {
            toolbarState.isTableTab = false
            toolbarState.isResultsCollapsed = false
        }
    }

    private func evictInactiveTabs(excluding activeTabIds: Set<UUID>) {
        let start = Date()
        let candidates: [(tab: QueryTab, rows: TableRows)] = tabManager.tabs.compactMap { tab in
            guard !activeTabIds.contains(tab.id),
                  tab.execution.lastExecutedAt != nil,
                  !tab.pendingChanges.hasChanges,
                  let rows = tabSessionRegistry.existingTableRows(for: tab.id),
                  !tabSessionRegistry.isEvicted(tab.id),
                  !rows.rows.isEmpty
            else { return nil }
            return (tab, rows)
        }

        let sorted = candidates.sorted {
            let t0 = $0.tab.execution.lastExecutedAt ?? .distantFuture
            let t1 = $1.tab.execution.lastExecutedAt ?? .distantFuture
            if t0 != t1 { return t0 < t1 }
            let size0 = MemoryPressureAdvisor.estimatedFootprint(
                rowCount: $0.rows.rows.count,
                columnCount: $0.rows.columns.count
            )
            let size1 = MemoryPressureAdvisor.estimatedFootprint(
                rowCount: $1.rows.rows.count,
                columnCount: $1.rows.columns.count
            )
            return size0 > size1
        }

        let maxInactiveLoaded = MemoryPressureAdvisor.budgetForInactiveTabs()
        guard sorted.count > maxInactiveLoaded else {
            Self.lifecycleLogger.debug(
                "[switch] evictInactiveTabs no-op candidates=\(sorted.count) budget=\(maxInactiveLoaded) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
            )
            return
        }
        let toEvict = sorted.dropLast(maxInactiveLoaded)

        for entry in toEvict {
            tabSessionRegistry.evict(for: entry.tab.id)
            if let index = tabManager.tabs.firstIndex(where: { $0.id == entry.tab.id }) {
                // Bump QueryTab.loadEpoch to invalidate the `.task(id:)` key in
                // MainEditorContentView, so the next selection of this tab
                // triggers lazy-load. The session-side bump is not observed.
                tabManager.tabs[index].loadEpoch &+= 1
            }
        }
        Self.lifecycleLogger.debug(
            "[switch] evictInactiveTabs evicted=\(toEvict.count) keptInactive=\(maxInactiveLoaded) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
        )
    }
}
