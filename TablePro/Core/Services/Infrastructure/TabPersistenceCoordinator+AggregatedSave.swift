//
//  TabPersistenceCoordinator+AggregatedSave.swift
//  TablePro
//

import Foundation
import os

extension TabPersistenceCoordinator {
    /// Saves the connection's tabs. An empty list leaves the saved state alone: only the user
    /// closing every tab discards it, and that consent is expressed by `closeTabsByUser`.
    func saveAggregated() {
        let tabs = MainContentCoordinator.aggregatedTabs(for: connectionId)
        guard !tabs.isEmpty else { return }
        let selectedId = MainContentCoordinator.aggregatedSelectedTabId(for: connectionId)
        saveNow(tabs: tabs, selectedTabId: selectedId)
    }

    /// The disconnect and window-close paths, which are synchronous because the run loop may not
    /// service a Task before everything holding these tabs is torn down. Ending a session is not
    /// closing your tabs, so this never clears.
    func saveAggregatedSync() {
        let tabs = MainContentCoordinator.aggregatedTabs(for: connectionId)
        guard !tabs.isEmpty else { return }
        let selectedId = MainContentCoordinator.aggregatedSelectedTabId(for: connectionId)
        saveNowSync(tabs: tabs, selectedTabId: selectedId)
    }
}
