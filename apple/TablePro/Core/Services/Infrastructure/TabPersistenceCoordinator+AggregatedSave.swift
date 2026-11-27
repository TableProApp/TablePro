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
        let fingerprint = currentFingerprint()
        let tabs = MainContentCoordinator.aggregatedTabs(for: connectionId)
        guard !tabs.isEmpty else { return }
        let selectedId = MainContentCoordinator.aggregatedSelectedTabId(for: connectionId)
        if saveNow(tabs: tabs, selectedTabId: selectedId) { savedFingerprint = fingerprint }
    }

    /// The change-driven save. Returns before building any tab's saved form when no window's tabs, selection, text,
    /// caret or grid selection moved, and the browsed container did not either, since the last save that went out.
    func saveAggregatedIfChanged() {
        guard currentFingerprint() != savedFingerprint else { return }
        saveAggregated()
    }

    func currentFingerprint() -> PersistenceFingerprint {
        let session = DatabaseManager.shared.session(for: connectionId)
        return PersistenceFingerprint(
            generations: MainContentCoordinator.persistenceGenerations(for: connectionId),
            database: session?.browseDatabase,
            schema: session?.browseSchema
        )
    }

    /// The disconnect and window-close paths, which are synchronous because the run loop may not
    /// service a Task before everything holding these tabs is torn down. Ending a session is not
    /// closing your tabs, so this never clears.
    func saveAggregatedSync() {
        let tabs = MainContentCoordinator.aggregatedTabs(for: connectionId)
        guard !tabs.isEmpty else { return }
        let selectedId = MainContentCoordinator.aggregatedSelectedTabId(for: connectionId)
        let fingerprint = currentFingerprint()
        if saveNowSync(tabs: tabs, selectedTabId: selectedId) { savedFingerprint = fingerprint }
    }
}
