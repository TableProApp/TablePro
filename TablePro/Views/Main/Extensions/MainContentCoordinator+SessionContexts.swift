//
//  MainContentCoordinator+SessionContexts.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

extension MainContentCoordinator {
    func loadSessionContexts() async {
        guard toolbarState.connectionState == .connected,
              let driver = services.databaseManager.driver(for: connectionId) else {
            sessionContexts = []
            return
        }
        do {
            sessionContexts = try await driver.fetchSessionContexts() ?? []
        } catch {
            Self.logger.warning("Failed to load session contexts: \(error.localizedDescription)")
            sessionContexts = []
        }
    }

    func switchSessionContext(id: String, to value: String) async {
        guard let driver = services.databaseManager.driver(for: connectionId) else { return }
        do {
            try await driver.switchSessionContext(id: id, to: value)
            await loadSessionContexts()
            AppCommands.shared.refreshData.send(connectionId)
        } catch {
            AlertHelper.showErrorSheet(
                title: String(localized: "Switch Failed"),
                message: error.localizedDescription,
                window: contentWindow
            )
        }
    }
}
