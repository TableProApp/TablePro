//
//  TabPersistenceCoordinator+AggregatedSave.swift
//  TablePro
//

import Foundation

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

    /// Synchronous variant for the window-close path, where the run loop may
    /// not be available to service Tasks before the window tears down. This is the one
    /// path where an empty aggregate means the user closed everything, so it clears.
    func saveOrClearAggregatedSync() {
        let aggregatedTabs = MainContentCoordinator.aggregatedTabs(for: connectionId)
        if aggregatedTabs.isEmpty {
            clearForUserClosedAllTabs()
        } else {
            let selectedId = MainContentCoordinator.aggregatedSelectedTabId(for: connectionId)
            saveNowSync(windowedTabs: aggregatedTabs, selectedTabId: selectedId)
        }
    }
}
