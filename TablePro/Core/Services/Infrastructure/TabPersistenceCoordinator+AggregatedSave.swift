//
//  TabPersistenceCoordinator+AggregatedSave.swift
//  TablePro
//

import Foundation
import os

extension TabPersistenceCoordinator {
    /// Save persisted state from the tabs aggregated across all windows for the connection.
    /// Prevents the per-window close path from clobbering state when sibling windows still
    /// have open tabs. An empty aggregate leaves the saved state alone; only the user closing
    /// every tab discards it, through `saveOrClearAggregatedSync()`.
    func saveAggregated() {
        let aggregatedTabs = MainContentCoordinator.aggregatedTabs(for: connectionId)
        guard !aggregatedTabs.isEmpty else { return }
        let selectedId = MainContentCoordinator.aggregatedSelectedTabId(for: connectionId)
        saveNow(windowedTabs: aggregatedTabs, selectedTabId: selectedId)
    }

    /// The disconnect path: synchronous like the close path, because the session is about to go
    /// away and every coordinator holding these tabs is torn down straight after, and
    /// never-clearing like `saveAggregated()`, because the user asked to end a session, not to
    /// close their tabs. `saveAggregated()` alone cannot serve this: it defers the write through
    /// `scheduleSave`, which cancels the previous task, so a sibling window's save can drop it.
    func saveAggregatedSync() {
        let aggregatedTabs = MainContentCoordinator.aggregatedTabs(for: connectionId)
        guard !aggregatedTabs.isEmpty else { return }
        let selectedId = MainContentCoordinator.aggregatedSelectedTabId(for: connectionId)
        saveNowSync(windowedTabs: aggregatedTabs, selectedTabId: selectedId)
    }

    /// Synchronous variant for the window-close path, where the run loop may
    /// not be available to service Tasks before the window tears down. This is the one
    /// path where an empty aggregate means the user closed everything, so it clears.
    func saveOrClearAggregatedSync() {
        let aggregatedTabs = MainContentCoordinator.aggregatedTabs(for: connectionId)
        if aggregatedTabs.isEmpty {
            guard hasObservedTabs else {
                Self.logger.info(
                    "[persist] clear withheld, window never held a tab connId=\(self.connectionId, privacy: .public)"
                )
                return
            }
            clearForUserClosedAllTabs()
        } else {
            let selectedId = MainContentCoordinator.aggregatedSelectedTabId(for: connectionId)
            saveNowSync(windowedTabs: aggregatedTabs, selectedTabId: selectedId)
        }
    }
}
