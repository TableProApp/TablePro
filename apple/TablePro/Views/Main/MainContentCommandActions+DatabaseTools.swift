//
//  MainContentCommandActions+DatabaseTools.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCommandActions {
    func createView() {
        coordinator?.createView()
    }

    func createSequence() {
        coordinator?.createSequence()
    }

    func createNewTable() {
        coordinator?.createNewTable()
    }

    func showERDiagram() {
        coordinator?.showERDiagram()
    }

    func showServerDashboard() {
        coordinator?.showSingletonTab(.serverDashboard)
    }

    func showQueryInsights() {
        coordinator?.showSingletonTab(.insights)
    }

    func showTableHealth() {
        coordinator?.showSingletonTab(.tableHealth)
    }

    var supportsServerDashboard: Bool {
        guard let type = coordinator?.connection.type else { return false }
        return ServerDashboardQueryProviderFactory.supportsDashboard(for: type)
    }

    var supportsTableHealth: Bool {
        guard let type = coordinator?.connection.type else { return false }
        return TableHealthProviderFactory.provider(for: type) != nil
    }

    func showUsersAndRoles() {
        coordinator?.showSingletonTab(.usersRoles)
    }

    var supportsUserManagement: Bool {
        guard let connectionId = coordinator?.connectionId,
              let adapter = DatabaseManager.shared.driver(for: connectionId) as? PluginDriverAdapter
        else { return false }
        return adapter.schemaPluginDriver.capabilities.contains(.userManagement)
    }
}
