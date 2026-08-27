//
//  MainSplitViewController+DatabaseMenuActions.swift
//  TablePro
//

import AppKit
import SwiftUI

extension MainSplitViewController {
    @objc func switchConnection(_ sender: Any?) {
        openConnectionSwitcher()
    }

    /// Presented by the window, not by the selected connection's actions like everything else in
    /// this file. The switcher lists every connection the app has open and every one the user has
    /// saved, and it reads none of that from a session, so nothing about it belongs to the
    /// connection on screen. That connection going away is exactly when a user reaches for it, and
    /// routing it through `commandActions` made it do nothing at that moment: `releaseSession`
    /// nils the actions, so Switch Connection and Control-Command-C were dead over the very pane
    /// telling the user to reconnect or pick another connection.
    func openConnectionSwitcher() {
        view.window?.makeFirstResponder(nil)
        commandActions?.dismissScopeSwitcher()
        switcherPresenter.present(
            from: view.window,
            anchoredTo: MainWindowToolbar.connectionGroup,
            contentSize: ConnectionSwitcherPopover.contentSize
        ) { dismiss in
            ConnectionSwitcherPopover(dismiss: dismiss)
        }
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

    @objc func setFavoriteDatabaseEnvironment(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let environment = FavoriteDatabaseEnvironment(rawValue: raw) else { return }
        commandActions?.setActiveDatabaseFavorite(environment: environment)
    }

    @objc func removeFavoriteDatabase(_ sender: Any?) {
        commandActions?.removeActiveDatabaseFavorite()
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
