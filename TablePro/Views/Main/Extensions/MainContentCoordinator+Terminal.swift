//
//  MainContentCoordinator+Terminal.swift
//  TablePro
//

import AppKit

extension MainContentCoordinator {
    func openTerminal() {
        if let existing = tabManager.tabs.first(where: { $0.tabType == .terminal }) {
            tabManager.selectedTabId = existing.id
            return
        }

        tabManager.addTerminalTab(databaseName: activeDatabaseName)
    }
}
