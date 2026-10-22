//
//  MainContentCommandActions+TabPinning.swift
//  TablePro
//

import Foundation

extension MainContentCommandActions {
    var canTogglePinnedTab: Bool {
        coordinator?.tabManager.selectedTab != nil
    }

    var isSelectedTabPinned: Bool {
        coordinator?.tabManager.selectedTab?.isPinned ?? false
    }

    func togglePinnedTab() {
        guard let manager = coordinator?.tabManager, let tab = manager.selectedTab else { return }
        manager.setPinned(!tab.isPinned, id: tab.id)
    }
}
