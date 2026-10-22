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
        coordinator?.showServerDashboard()
    }

    func showQueryInsights() {
        coordinator?.showQueryInsights()
    }

    var supportsServerDashboard: Bool {
        guard let type = coordinator?.connection.type else { return false }
        return ServerDashboardQueryProviderFactory.supportsDashboard(for: type)
    }

    func showUsersAndRoles() {
        coordinator?.showUsersAndRoles()
    }

    var supportsUserManagement: Bool {
        guard let connectionId = coordinator?.connectionId,
              let adapter = DatabaseManager.shared.driver(for: connectionId) as? PluginDriverAdapter
        else { return false }
        return adapter.schemaPluginDriver.capabilities.contains(.userManagement)
    }
}
