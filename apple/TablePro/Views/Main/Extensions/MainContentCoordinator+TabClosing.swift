//
//  MainContentCoordinator+TabClosing.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    // User-initiated, the consent `clearForUserClosedAllTabs` needs; automatic paths never clear saved tabs.
    func closeTabsByUser(ids: [UUID]) {
        flushColumnLayoutPersistence()
        for id in ids {
            guard let tab = tabManager.tabs.first(where: { $0.id == id }) else { continue }
            // A close removes the tab before the selection moves, so this is the only save of filter rows never applied.
            saveLastFilters(of: tab)
            if tab.tabType.isTransient {
                RoutineDebugSessions.shared.endSession(forTab: id, window: contentWindow)
            } else {
                RecentlyClosedTabStore.shared.push(tab: tab, connection: connection)
            }
            releaseResources(of: tab)
            releaseExecution(of: tab)
            tabManager.closeTab(id: id)
        }
        guard tabManager.tabs.allSatisfy({ $0.tabType.isTransient }) else { return }
        persistence.clearForUserClosedAllTabs()
    }

    // Not a close, so nothing goes to Reopen Closed Tab; the unparented source view will not save, so this is the only save.
    internal func takeTabForMove(id: UUID) -> QueryTab? {
        guard canMoveTabToConnection(id),
              let tab = tabManager.tabs.first(where: { $0.id == id }) else { return nil }
        let moved = enrichedForPersistence(tab)
        // The live caret is the moved tab's: closing selects a neighbour without mounting its editor, so the save would write it there.
        if tabManager.selectedTabId == id {
            cursorPositions = []
        }
        flushColumnLayoutPersistence()
        releaseResources(of: tab)
        releaseExecution(of: tab)
        tabSessionRegistry.unregister(id: id)
        tabManager.closeTab(id: id)
        cleanupTabCaches(openTabIds: Set(tabManager.tabs.map(\.id)))
        services.schemaProviderRegistry.reclaimUnheldProviders(for: connectionId)
        persistence.saveAggregated()
        // Moving the last tab out empties the connection like closing it; left on disk, the tab would restore here as a duplicate.
        if Self.aggregatedTabs(for: connectionId).isEmpty {
            persistence.clearForUserClosedAllTabs()
        }
        return moved
    }

    // Not a user close: nothing goes to Reopen Closed Tab (it would reopen onto an error) and the saved tab set is kept.
    func closeTabsForRemovedObjects(ids: [UUID]) {
        for id in ids {
            // Discarded, not flushed: the object is gone and its saved layout was cleared, so a write would put it back.
            releaseGridModel(forTab: id, persistingLayout: false)
            guard let tab = tabManager.tabs.first(where: { $0.id == id }) else { continue }
            releaseResources(of: tab)
            releaseExecution(of: tab)
            tabSessionRegistry.removeTableRows(for: id)
            tabManager.closeTab(id: id)
        }
    }

    // All keyed by tab id, so a stale entry would hand another tab's state to the next tab given that id.
    func cleanupTabCaches(openTabIds: Set<UUID>) {
        prune(&displayFormatsCache, keeping: openTabIds)
        for tabId in Array(dataGridEntries.keys) where !openTabIds.contains(tabId) {
            releaseGridModel(forTab: tabId)
        }
        prune(&tableMetadataCache, keeping: openTabIds)
        prune(&createTableDrafts, keeping: openTabIds)
        prune(&userTypeEditors, keeping: openTabIds)
        prune(&erDiagramModels, keeping: openTabIds)
        prune(&navigationHistories, keeping: openTabIds)
        toolbarState.forgetQueryTimings(keeping: openTabIds)
        for (tabId, session) in structureSessions where !openTabIds.contains(tabId) {
            session.releaseViewWiring()
            structureSessions.removeValue(forKey: tabId)
        }
    }

    // Rewrites only when something went, so a tab change does not pay for a filtered copy every time.
    private func prune<Value>(_ cache: inout [UUID: Value], keeping openTabIds: Set<UUID>) {
        guard cache.keys.contains(where: { !openTabIds.contains($0) }) else { return }
        cache = cache.filter { openTabIds.contains($0.key) }
    }

    // A retarget keeps the id, so stale caches (staged ALTERs) would prompt to apply the previous table's changes.
    func releaseRetargetedTabState(for tabId: UUID) {
        tableMetadataCache.removeValue(forKey: tabId)
        tabSessionRegistry.forgetFreshness(for: tabId)
        structureSessions.removeValue(forKey: tabId)?.releaseViewWiring()
        createTableDrafts.removeValue(forKey: tabId)
        erDiagramModels.removeValue(forKey: tabId)
        tabsWithStagedPrincipals.remove(tabId)
        toolbarState.hasCreateTablePending = false
        toolbarState.hasPrincipalChanges = false
        toolbarState.hasTypeChanges = false
    }

    // Before `closeTab(id:)`, which hides the tab from `handleTabChange`; stale edits would later save to the wrong database.
    private func releaseResources(of tab: QueryTab) {
        tabsWithStagedPrincipals.remove(tab.id)
        structureSessions.removeValue(forKey: tab.id)?.releaseViewWiring()
        createTableDrafts.removeValue(forKey: tab.id)
        userTypeEditors.removeValue(forKey: tab.id)
        erDiagramModels.removeValue(forKey: tab.id)
        navigationHistories.removeValue(forKey: tab.id)
        releaseGridModel(forTab: tab.id)
        tableMetadataCache.removeValue(forKey: tab.id)
        guard isSelectedTab(tab) else { return }
        changeManager.clearChangesAndUndoHistory()
        toolbarState.hasCreateTablePending = false
        toolbarState.hasPrincipalChanges = false
        toolbarState.hasTypeChanges = false
    }

    // A closed tab kept its registry claim, so a reopened tab with the same id had its load refused as a duplicate.
    internal func releaseExecution(of tab: QueryTab) {
        reportEndedExecutions(tabExecution.invalidate(tab.id, reason: .abandoned).map { [$0] } ?? [])
        cancelTableLoad(for: tab.id)
        cancelRowCountTask(for: tab.id)
        cancelQueryTask(for: tab.id, delivery: .background)
    }
}
