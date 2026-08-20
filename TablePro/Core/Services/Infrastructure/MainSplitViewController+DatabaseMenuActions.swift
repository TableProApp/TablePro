//
//  MainSplitViewController+DatabaseMenuActions.swift
//  TablePro
//

import AppKit

extension MainSplitViewController {
    @objc func switchConnection(_ sender: Any?) {
        commandActions?.openConnectionSwitcher()
    }

    @objc func openContainerSwitcher(_ sender: Any?) {
        commandActions?.openDatabaseSwitcher()
    }

    @objc func openQuickSwitcher(_ sender: Any?) {
        commandActions?.openQuickSwitcher()
    }

    @objc func refreshDatabase(_ sender: Any?) {
        commandActions?.refresh()
    }

    @objc func createNewTable(_ sender: Any?) {
        commandActions?.createNewTable()
    }

    @objc func createNewView(_ sender: Any?) {
        commandActions?.createView()
    }

    @objc func createNewDatabase(_ sender: Any?) {
        commandActions?.createDatabase()
    }

    @objc func showTableStructure(_ sender: Any?) {
        commandActions?.showTableStructure()
    }

    @objc func editViewDefinition(_ sender: Any?) {
        commandActions?.editViewDefinition()
    }

    @objc func runMaintenanceOperation(_ sender: Any?) {
        guard let operation = (sender as? NSMenuItem)?.representedObject as? String else { return }
        commandActions?.runMaintenanceOperation(operation)
    }

    @objc func switchToSchema(_ sender: Any?) {
        guard let schema = (sender as? NSMenuItem)?.representedObject as? String,
              let coordinator = commandActions?.coordinator else { return }
        Task { await coordinator.switchSchema(to: schema) }
    }

    @objc func truncateTable(_ sender: Any?) {
        commandActions?.truncateTables()
    }

    @objc func showERDiagram(_ sender: Any?) {
        commandActions?.showERDiagram()
    }

    @objc func showServerDashboard(_ sender: Any?) {
        commandActions?.showServerDashboard()
    }

    @objc func showUsersAndRoles(_ sender: Any?) {
        commandActions?.showUsersAndRoles()
    }

    @objc func showQueryInsights(_ sender: Any?) {
        commandActions?.showQueryInsights()
    }
}
