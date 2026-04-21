//
//  MainContentCoordinator+Terminal.swift
//  TablePro
//

import AppKit

extension MainContentCoordinator {
    func openTerminal() {
        let session = DatabaseManager.shared.session(for: connectionId)
        let dbName = session?.activeDatabase ?? connection.database

        if tabManager.tabs.isEmpty {
            tabManager.addTerminalTab(databaseName: dbName)
            return
        }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .terminal,
            databaseName: dbName
        )
        WindowManager.shared.openTab(payload: payload)
    }
}
