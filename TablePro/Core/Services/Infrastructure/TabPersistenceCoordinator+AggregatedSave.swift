//
//  TabPersistenceCoordinator+AggregatedSave.swift
//  TablePro
//

import Foundation

extension TabPersistenceCoordinator {
    /// Save or clear persisted state based on tabs aggregated across all windows
    /// for the connection. Prevents the per-window close path from clobbering
    /// state when sibling windows still have open tabs.
    func saveOrClearAggregated() {
        let aggregatedTabs = MainContentCoordinator.aggregatedTabs(for: connectionId)
        if aggregatedTabs.isEmpty {
            clearSavedState()
        } else {
            let selectedId = MainContentCoordinator.aggregatedSelectedTabId(for: connectionId)
            saveNow(tabs: aggregatedTabs, selectedTabId: selectedId)
        }
    }

    /// Synchronous variant for the window-close path, where the run loop may
    /// not be available to service Tasks before the window tears down.
    func saveOrClearAggregatedSync() {
        let aggregatedTabs = MainContentCoordinator.aggregatedTabs(for: connectionId)
        if aggregatedTabs.isEmpty {
            saveNowSync(tabs: [], selectedTabId: nil)
        } else {
            let selectedId = MainContentCoordinator.aggregatedSelectedTabId(for: connectionId)
            saveNowSync(tabs: aggregatedTabs, selectedTabId: selectedId)
        }
    }
}
