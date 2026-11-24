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

    // False when the type tab's queue is still staged after the attempt, which stands a close down.
    func applyTypeChanges(ofTab tabId: UUID?) async -> Bool {
        guard let coordinator, let tabId,
              coordinator.userTypeEditors[tabId]?.hasChanges == true else { return true }
        return await coordinator.applyUserTypeChanges(tabId: tabId).allowsClose
    }

    // The type tabs a window or batch close asked about, other than the one on screen.
    func applyBackgroundTypeChanges(in tabs: [QueryTab], besides onScreenId: UUID?) async -> Bool {
        guard let coordinator else { return true }
        for tab in tabs where tab.id != onScreenId && coordinator.hasStagedTypeChanges(in: tab) {
            guard await coordinator.applyUserTypeChanges(tabId: tab.id).allowsClose else { return false }
        }
        return true
    }
}
