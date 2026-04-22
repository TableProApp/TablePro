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

        let session = DatabaseManager.shared.session(for: connectionId)
        let dbName = session?.activeDatabase ?? connection.database
        tabManager.addTerminalTab(databaseName: dbName)
    }
}
