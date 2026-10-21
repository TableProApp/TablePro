//
//  MainContentCommandActions+UserTypes.swift
//  TablePro
//

import Foundation

extension MainContentCommandActions {
    /// Whether Save went to the selected type tab's queue.
    func saveSelectedTypeChanges() -> Bool {
        guard let coordinator, let tabId = coordinator.tabManager.selectedTabId,
              coordinator.userTypeEditors[tabId]?.hasChanges == true else { return false }
        coordinator.saveUserTypeChanges(tabId: tabId)
        return true
    }

    /// False when the selected type tab's queue is still staged after the attempt, which stands a
    /// close down.
    func applySelectedTypeChanges() async -> Bool {
        guard let coordinator, let tabId = coordinator.tabManager.selectedTabId,
              coordinator.userTypeEditors[tabId]?.hasChanges == true else { return true }
        return await coordinator.applyUserTypeChanges(tabId: tabId).allowsClose
    }

    /// The type tabs a window or batch close asked about that are not on screen.
    func applyBackgroundTypeChanges(in tabs: [QueryTab]) async -> Bool {
        guard let coordinator else { return true }
        let selectedId = coordinator.tabManager.selectedTabId
        for tab in tabs where tab.id != selectedId && coordinator.hasStagedTypeChanges(in: tab) {
            guard await coordinator.applyUserTypeChanges(tabId: tab.id).allowsClose else { return false }
        }
        return true
    }
}
