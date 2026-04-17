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
        selectedRowIndices: inout Set<Int>,
        tabs: [QueryTab]
    ) {
        let start = Date()
        Self.lifecycleLogger.info(
            "[switch] handleTabChange start from=\(oldTabId?.uuidString ?? "nil", privacy: .public) to=\(newTabId?.uuidString ?? "nil", privacy: .public) connId=\(self.connectionId, privacy: .public) tabsCount=\(self.tabManager.tabs.count)"
        )
        isHandlingTabSwitch = true
        defer {
            isHandlingTabSwitch = false
            Self.lifecycleLogger.info(
                "[switch] handleTabChange done to=\(newTabId?.uuidString ?? "nil", privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
            )
        }

        // Persist the outgoing tab's unsaved changes and filter state so they survive the switch
        if let oldId = oldTabId,
           let oldIndex = tabManager.tabs.firstIndex(where: { $0.id == oldId })
        {
            if changeManager.hasChanges {
                tabManager.tabs[oldIndex].pendingChanges = changeManager.saveState()
            }
            tabManager.tabs[oldIndex].filterState = filterStateManager.saveToTabState()
            if let tableName = tabManager.tabs[oldIndex].tableName {
                filterStateManager.saveLastFilters(for: tableName)
            }
            saveColumnVisibilityToTab()
            saveColumnLayoutForTable()
        }

        if tabManager.tabs.count > 2 {
            let activeIds: Set<UUID> = Set([oldTabId, newTabId].compactMap { $0 })
            evictInactiveTabs(excluding: activeIds)
        }

        if let newId = newTabId,
           let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId }) {
            let newTab = tabManager.tabs[newIndex]

            // Restore filter state for new tab
            filterStateManager.restoreFromTabState(newTab.filterState)

            // Restore column visibility for new tab
            columnVisibilityManager.restoreFromColumnLayout(newTab.columnLayout.hiddenColumns)

            selectedRowIndices = newTab.selectedRowIndices
            toolbarState.isTableTab = newTab.tabType == .table
            toolbarState.isResultsCollapsed = newTab.isResultsCollapsed

            // Configure change manager without triggering reload yet — we'll fire a single
            // reloadVersion bump below after everything is set up.
            let pendingState = newTab.pendingChanges
            if pendingState.hasChanges {
                changeManager.restoreState(from: pendingState, tableName: newTab.tableName ?? "", databaseType: connection.type)
            } else {
                changeManager.configureForTable(
                    tableName: newTab.tableName ?? "",
                    columns: newTab.resultColumns,
                    primaryKeyColumns: newTab.primaryKeyColumns.isEmpty
                        ? newTab.resultColumns.prefix(1).map { $0 }
                        : newTab.primaryKeyColumns,
                    databaseType: connection.type,
                    triggerReload: false
                )
            }

            // Defer reloadVersion bump — only needed when we won't run a query.
            // When a query runs, executeQueryInternal Phase 1 sets new result data
            // that triggers its own SwiftUI update; bumping beforehand causes a
            // redundant re-evaluation that blocks the Task executor (15-40ms).

            if !newTab.databaseName.isEmpty {
                let currentDatabase: String
                if let session = DatabaseManager.shared.session(for: connectionId) {
                    currentDatabase = session.activeDatabase
                } else {
                    currentDatabase = connection.database
                }

                if newTab.databaseName != currentDatabase {
                    Self.lifecycleLogger.info(
                        "[switch] handleTabChange triggering switchDatabase from=\(currentDatabase, privacy: .public) to=\(newTab.databaseName, privacy: .public)"
                    )
                    changeManager.reloadVersion += 1
                    Task { @MainActor in
                        await switchDatabase(to: newTab.databaseName)
                    }
                    return  // switchDatabase will re-execute the query
                }
            }

            // If the tab shows isExecuting but has no results, the previous query was
            // likely cancelled when the user rapidly switched away. Force-clear the stale
            // flag so the lazy-load check below can re-execute the query.
            if newTab.isExecuting && newTab.resultRows.isEmpty && newTab.lastExecutedAt == nil {
                let tabId = newId
                Task { @MainActor [weak self] in
                    guard let self,
                          let idx = self.tabManager.tabs.firstIndex(where: { $0.id == tabId }),
                          self.tabManager.tabs[idx].isExecuting else { return }
                    self.tabManager.tabs[idx].isExecuting = false
                }
            }

            let isEvicted = newTab.rowBuffer.isEvicted
            let needsLazyQuery = newTab.tabType == .table
                && (newTab.resultRows.isEmpty || isEvicted)
                && (newTab.lastExecutedAt == nil || isEvicted)
                && newTab.errorMessage == nil
                && !newTab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if needsLazyQuery {
                if let session = DatabaseManager.shared.session(for: connectionId), session.isConnected {
                    Self.lifecycleLogger.info(
                        "[switch] handleTabChange lazy query executing (eviction=\(isEvicted)) tabId=\(newId, privacy: .public)"
                    )
                    executeTableTabQueryDirectly()
                } else {
                    Self.lifecycleLogger.info(
                        "[switch] handleTabChange lazy query deferred (not connected) tabId=\(newId, privacy: .public)"
                    )
                    changeManager.reloadVersion += 1
                    needsLazyLoad = true
                }
            } else {
                changeManager.reloadVersion += 1
            }
        } else {
            toolbarState.isTableTab = false
            toolbarState.isResultsCollapsed = false
            filterStateManager.clearAll()
        }
    }

    private func evictInactiveTabs(excluding activeTabIds: Set<UUID>) {
        let start = Date()
        let candidates = tabManager.tabs.filter {
            !activeTabIds.contains($0.id)
                && !$0.rowBuffer.isEvicted
                && !$0.resultRows.isEmpty
                && $0.lastExecutedAt != nil
                && !$0.pendingChanges.hasChanges
        }

        // Sort by oldest first, breaking ties by largest estimated footprint first
        let sorted = candidates.sorted {
            let t0 = $0.lastExecutedAt ?? .distantFuture
            let t1 = $1.lastExecutedAt ?? .distantFuture
            if t0 != t1 { return t0 < t1 }
            let size0 = MemoryPressureAdvisor.estimatedFootprint(
                rowCount: $0.rowBuffer.rows.count,
                columnCount: $0.rowBuffer.columns.count
            )
            let size1 = MemoryPressureAdvisor.estimatedFootprint(
                rowCount: $1.rowBuffer.rows.count,
                columnCount: $1.rowBuffer.columns.count
            )
            return size0 > size1
        }

        let maxInactiveLoaded = MemoryPressureAdvisor.budgetForInactiveTabs()
        guard sorted.count > maxInactiveLoaded else {
            Self.lifecycleLogger.info(
                "[switch] evictInactiveTabs no-op candidates=\(sorted.count) budget=\(maxInactiveLoaded) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
            )
            return
        }
        let toEvict = sorted.dropLast(maxInactiveLoaded)

        for tab in toEvict {
            tab.rowBuffer.evict()
        }
        Self.lifecycleLogger.info(
            "[switch] evictInactiveTabs evicted=\(toEvict.count) keptInactive=\(maxInactiveLoaded) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
        )
    }
}
