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
    /// Schedule a tab switch with zero synchronous @Observable mutations.
    /// The ZStack opacity flip happens from selectedTabId binding alone.
    /// All state work (save outgoing, MRU, title, sidebar, persist) is
    /// deferred to Phase 2 Task which coalesces rapid Cmd+1/2/3 spam.
    func scheduleTabSwitch(
        from oldTabId: UUID?,
        to newTabId: UUID?
    ) {
        isHandlingTabSwitch = true

        // MRU tracking is lightweight (array append) — do synchronously
        if let newId = newTabId {
            tabManager.trackActivation(newId)
        }

        // Phase 2: Deferred — all state work coalesced via task cancellation.
        // During rapid Cmd+1/2/3, only the LAST switch's Phase 2 executes.
        tabSwitchTask?.cancel()
        let capturedOldId = oldTabId
        let capturedNewId = newTabId
        tabSwitchTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer { self.isHandlingTabSwitch = false }

            // Update toolbar and selection for the settled tab
            if let newId = capturedNewId,
               let newIndex = self.tabManager.tabs.firstIndex(where: { $0.id == newId }) {
                self.toolbarState.isTableTab = self.tabManager.tabs[newIndex].tabType == .table
            } else {
                self.toolbarState.isTableTab = false
                self.toolbarState.isResultsCollapsed = false
            }

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

            // Lazy query check for evicted/empty tabs
            guard let newId = capturedNewId,
                  let newIndex = self.tabManager.tabs.firstIndex(where: { $0.id == newId })
            else { return }
            let newTab = self.tabManager.tabs[newIndex]

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
                if let session = DatabaseManager.shared.session(for: self.connectionId), session.isConnected {
                    self.executeTableTabQueryDirectly()
                } else {
                    self.changeManager.reloadVersion += 1
                    self.needsLazyLoad = true
                }
            }

            // Notify view layer to update title, sidebar, and persistence
            // after deferred state has settled.
            self.onTabSwitchSettled?()
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
