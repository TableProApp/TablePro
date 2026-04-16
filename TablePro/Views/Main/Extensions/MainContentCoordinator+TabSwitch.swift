//
//  MainContentCoordinator+TabSwitch.swift
//  TablePro
//
//  Tab switching logic extracted from MainContentCoordinator
//  to keep the main class body within SwiftLint limits.
//

import Foundation

extension MainContentCoordinator {
    /// Schedule a tab switch. Phase 1 (synchronous): MRU tracking only.
    /// Phase 2 (deferred Task): save outgoing state, restore incoming
    /// shared managers, lazy query, sidebar/title/persist settlement.
    /// Rapid Cmd+1/2/3 coalesces — only the LAST switch's Phase 2 runs.
    func scheduleTabSwitch(
        from oldTabId: UUID?,
        to newTabId: UUID?
    ) {
        // isHandlingTabSwitch is true only during this synchronous block.
        // onChange handlers check it to skip cascading work.
        isHandlingTabSwitch = true
        defer { isHandlingTabSwitch = false }

        if let newId = newTabId {
            tabManager.trackActivation(newId)
        }

        // Save outgoing tab state synchronously (Phase 1) so it's never lost
        // during rapid Cmd+1/2/3 coalescing where Phase 2 Tasks get cancelled.
        if let oldId = oldTabId,
           let oldIndex = tabManager.tabs.firstIndex(where: { $0.id == oldId })
        {
            var tab = tabManager.tabs[oldIndex]
            if changeManager.hasChanges {
                tab.pendingChanges = changeManager.saveState()
            }
            tab.filterState = filterStateManager.saveToTabState()
            tabManager.tabs[oldIndex] = tab
            if let tableName = tab.tableName {
                filterStateManager.saveLastFilters(for: tableName)
            }
            saveColumnVisibilityToTab()
            saveColumnLayoutForTable()
        }

        // Phase 2: Deferred — restore incoming state + lazy query.
        // During rapid Cmd+1/2/3, only the LAST switch's Phase 2 executes.
        tabSwitchTask?.cancel()
        let capturedNewId = newTabId
        tabSwitchTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }

            // Restore incoming tab shared state.
            guard let newId = capturedNewId,
                  let newIndex = self.tabManager.tabs.firstIndex(where: { $0.id == newId })
            else {
                self.toolbarState.isTableTab = false
                self.toolbarState.isResultsCollapsed = false
                self.filterStateManager.clearAll()
                return
            }
            let newTab = self.tabManager.tabs[newIndex]

            // Guard each mutation — skip when the value is already correct.
            // Avoids unnecessary @Observable notifications that would cause
            // ALL NSHostingViews to re-evaluate (expensive for tabs with many rows).
            let isTable = newTab.tabType == .table
            if self.toolbarState.isTableTab != isTable {
                self.toolbarState.isTableTab = isTable
            }
            if self.toolbarState.isResultsCollapsed != newTab.isResultsCollapsed {
                self.toolbarState.isResultsCollapsed = newTab.isResultsCollapsed
            }
            self.filterStateManager.restoreFromTabState(newTab.filterState)
            self.restoreColumnVisibilityFromTab(newTab)

            // Reconfigure change manager only when the table actually changed
            let newTableName = newTab.tableName ?? ""
            let pendingState = newTab.pendingChanges
            if pendingState.hasChanges {
                self.changeManager.restoreState(
                    from: pendingState,
                    tableName: newTableName,
                    databaseType: self.connection.type
                )
            } else if self.changeManager.tableName != newTableName
                || self.changeManager.columns != newTab.resultColumns
            {
                self.changeManager.configureForTable(
                    tableName: newTableName,
                    columns: newTab.resultColumns,
                    primaryKeyColumns: newTab.primaryKeyColumns.isEmpty
                        ? Array(newTab.resultColumns.prefix(1))
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

            let isEvicted = newTab.rowBuffer.isEvicted
            let needsLazyQuery = newTab.tabType == .table
                && (newTab.resultRows.isEmpty || isEvicted)
                && (newTab.lastExecutedAt == nil || isEvicted)
                && newTab.errorMessage == nil
                && !newTab.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if needsLazyQuery {
                // Only launch the query if this tab is still selected — during rapid switching
                // the user may have already moved to another tab.
                guard self.tabManager.selectedTabId == newId else { return }
                if let session = DatabaseManager.shared.session(for: self.connectionId), session.isConnected {
                    self.executeTableTabQueryDirectly()
                } else {
                    self.changeManager.reloadVersion += 1
                    self.needsLazyLoad = true
                }
            }

            // Only run settled callback if THIS tab is still selected.
            // During rapid Cmd+1/2/3, the user may have already switched to
            // another tab — running sidebar sync/title/persist for a stale
            // tab causes cascading onChange(selectedTables) body re-evals.
            guard self.tabManager.selectedTabId == capturedNewId else { return }
            self.onTabSwitchSettled?()
        }
    }
}
