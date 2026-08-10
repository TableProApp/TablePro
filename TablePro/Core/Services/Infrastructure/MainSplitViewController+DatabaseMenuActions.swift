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
}
