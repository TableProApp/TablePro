//
//  MainContentCoordinator+TabSwitch.swift
//  TablePro
//
//  Tab switching logic extracted from MainContentCoordinator
//  to keep the main class body within SwiftLint limits.
//

import Foundation

extension MainContentCoordinator {
    /// Two-phase tab switch: synchronous visual update + deferred state reconfiguration.
    /// Phase 1 (sync): Update only what's needed for immediate opacity flip (~1ms).
    /// Phase 2 (deferred): Save/restore shared managers in the next frame (~5ms, invisible).
    func handleTabChange(
        from oldTabId: UUID?,
        to newTabId: UUID?,
        selectedRowIndices: inout Set<Int>,
        tabs: [QueryTab]
    ) {
        isHandlingTabSwitch = true

        // Phase 1: Synchronous — minimal mutations for immediate visual switch
        if let newId = newTabId {
            tabManager.trackActivation(newId)
        }

        if let newId = newTabId,
           let newIndex = tabManager.tabs.firstIndex(where: { $0.id == newId }) {
            selectedRowIndices = tabManager.tabs[newIndex].selectedRowIndices
            toolbarState.isTableTab = tabManager.tabs[newIndex].tabType == .table
        }

        // Phase 2: Deferred — save outgoing + restore incoming shared manager state.
        // The ZStack opacity flip happens immediately in the current frame;
        // shared managers (@Observable) update in the next frame to avoid
        // cascading body re-evaluations that block the visual switch.
        // Cancel previous deferred task so rapid Cmd+1/Cmd+2 spam only
        // commits the final tab — intermediate switches are discarded.
        tabSwitchTask?.cancel()
        let capturedOldId = oldTabId
        let capturedNewId = newTabId
        tabSwitchTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer { self.isHandlingTabSwitch = false }

            // Save outgoing tab state (batch into single array write)
            if let oldId = capturedOldId,
               let oldIndex = self.tabManager.tabs.firstIndex(where: { $0.id == oldId }) {
                var tab = self.tabManager.tabs[oldIndex]
                if self.changeManager.hasChanges {
                    tab.pendingChanges = self.changeManager.saveState()
                }
                tab.filterState = self.filterStateManager.saveToTabState()
                self.tabManager.tabs[oldIndex] = tab
                if let tableName = tab.tableName {
                    self.filterStateManager.saveLastFilters(for: tableName)
                }
                self.saveColumnVisibilityToTab()
                self.saveColumnLayoutForTable()
            }

            guard !Task.isCancelled else { return }

            // Restore incoming tab state
            guard let newId = capturedNewId,
                  let newIndex = self.tabManager.tabs.firstIndex(where: { $0.id == newId })
            else {
                self.toolbarState.isTableTab = false
                self.toolbarState.isResultsCollapsed = false
                self.filterStateManager.clearAll()
                return
            }
            let newTab = self.tabManager.tabs[newIndex]

            self.filterStateManager.restoreFromTabState(newTab.filterState)
            self.columnVisibilityManager.restoreFromColumnLayout(newTab.columnLayout.hiddenColumns)
            self.toolbarState.isResultsCollapsed = newTab.isResultsCollapsed

            let pendingState = newTab.pendingChanges
            if pendingState.hasChanges {
                self.changeManager.restoreState(
                    from: pendingState,
                    tableName: newTab.tableName ?? "",
                    databaseType: self.connection.type
                )
            } else {
                self.changeManager.configureForTable(
                    tableName: newTab.tableName ?? "",
                    columns: newTab.resultColumns,
                    primaryKeyColumns: newTab.primaryKeyColumns.isEmpty
                        ? newTab.resultColumns.prefix(1).map { $0 }
                        : newTab.primaryKeyColumns,
                    databaseType: self.connection.type,
                    triggerReload: false
                )
            }

            // Database switch check
            if !newTab.databaseName.isEmpty {
                let currentDatabase = DatabaseManager.shared.session(for: self.connectionId)?.activeDatabase
                    ?? self.connection.database
                if newTab.databaseName != currentDatabase {
                    self.changeManager.reloadVersion += 1
                    await self.switchDatabase(to: newTab.databaseName)
                    return
                }
            }

            // Clear stale isExecuting flag
            if newTab.isExecuting && newTab.resultRows.isEmpty && newTab.lastExecutedAt == nil {
                if let idx = self.tabManager.tabs.firstIndex(where: { $0.id == newId }),
                   self.tabManager.tabs[idx].isExecuting {
                    self.tabManager.tabs[idx].isExecuting = false
                }
            }

            // Lazy query for evicted/empty tabs
            let isEvicted = newTab.rowBuffer.isEvicted
            let needsLazyQuery = newTab.tabType == .table
                && (newTab.resultRows.isEmpty || isEvicted)
                && (newTab.lastExecutedAt == nil || isEvicted)
                && newTab.errorMessage == nil
                && !newTab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if needsLazyQuery {
                if let session = DatabaseManager.shared.session(for: self.connectionId), session.isConnected {
                    self.executeTableTabQueryDirectly()
                } else {
                    self.changeManager.reloadVersion += 1
                    self.needsLazyLoad = true
                }
            }
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
