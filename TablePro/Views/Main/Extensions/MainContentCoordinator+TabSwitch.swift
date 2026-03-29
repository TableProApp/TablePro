//
//  MainContentCoordinator+TabSwitch.swift
//  TablePro
//
//  Tab switching logic extracted from MainContentCoordinator
//  to keep the main class body within SwiftLint limits.
//

import Foundation

extension MainContentCoordinator {
    func handleTabChange(
        from oldTabId: UUID?,
        to newTabId: UUID?,
        selectedRowIndices: inout Set<Int>,
        tabs: [QueryTab]
    ) {
        isHandlingTabSwitch = true
        defer { isHandlingTabSwitch = false }

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
            AppState.shared.isCurrentTabEditable = newTab.isEditable && !newTab.isView && newTab.tableName != nil
            toolbarState.isTableTab = newTab.tabType == .table
            AppState.shared.isTableTab = newTab.tabType == .table

            // Configure change manager without triggering reload yet — we'll fire a single
            // reloadVersion bump below after everything is set up.
            let pendingState = newTab.pendingChanges
            if pendingState.hasChanges {
                changeManager.restoreState(from: pendingState, tableName: newTab.tableName ?? "", databaseType: connection.type)
            } else {
                changeManager.configureForTable(
                    tableName: newTab.tableName ?? "",
                    columns: newTab.resultColumns,
                    primaryKeyColumn: newTab.primaryKeyColumn ?? newTab.resultColumns.first,
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
                && !newTab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if needsLazyQuery {
                if let session = DatabaseManager.shared.session(for: connectionId), session.isConnected {
                    executeTableTabQueryDirectly()
                } else {
                    changeManager.reloadVersion += 1
                    needsLazyLoad = true
                }
            } else {
                changeManager.reloadVersion += 1
            }
        } else {
            AppState.shared.isCurrentTabEditable = false
            toolbarState.isTableTab = false
            AppState.shared.isTableTab = false
        }
    }

    private func evictInactiveTabs(excluding activeTabIds: Set<UUID>) {
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
        guard sorted.count > maxInactiveLoaded else { return }
        let toEvict = sorted.dropLast(maxInactiveLoaded)

        for tab in toEvict {
            tab.rowBuffer.evict()
        }
    }
}
