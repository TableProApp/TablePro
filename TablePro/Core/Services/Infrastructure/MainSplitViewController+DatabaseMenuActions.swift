//
//  MainSplitViewController+DatabaseMenuActions.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

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
        switcherPresenter.present(
            from: view.window,
            anchoredTo: MainWindowToolbar.connection,
            hiddenBy: toolbarOwner?.visibility,
            subject: .connection,
            contentSize: ConnectionSwitcherPopover.contentSize
        ) { [selectedConnectionId] dismiss in
            ConnectionSwitcherPopover(dismiss: dismiss, currentConnectionId: selectedConnectionId)
        }
    }

    @objc func openContainerSwitcher(_ sender: Any?) {
        commandActions?.openDatabaseSwitcher()
    }

    /// The full chooser for the inner scope, which the checked Schema submenu beside it cannot
    /// replace: only the popover searches, favourites, drops and exports.
    @objc func openSchemaSwitcher(_ sender: Any?) {
        commandActions?.openScopeSwitcher(.schema)
    }

    @objc func createSchema(_ sender: Any?) {
        commandActions?.coordinator?.createSchema(database: nil)
    }

    /// Edits the schema the connection is browsing. The sidebar's own item edits the row that was
    /// clicked; this one is the route for a sidebar shape that draws no schema row at all.
    @objc func editCurrentSchema(_ sender: Any?) {
        guard let coordinator = commandActions?.coordinator,
              let schema = coordinator.toolbarState.currentSchema
                ?? DatabaseManager.shared.session(for: coordinator.connection.id)?.browseSchema
        else { return }
        coordinator.editSchema(
            .schema(
                database: coordinator.browseDatabaseName,
                schema: schema,
                isSystem: PluginManager.shared
                    .systemSchemaNames(for: coordinator.connection.type)
                    .contains(schema)
            )
        )
    }

    /// Reached through the workspace's coordinator rather than `commandActions`, which exists only
    /// once the browse content has appeared. A window opened straight into Agent mode never shows
    /// that content, so its Safe Mode list had no checkmark and no entry in it did anything.
    @objc func setSafeModeLevel(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let level = SafeModeLevel(rawValue: raw) else { return }
        workspaces.selected?.sessionState?.coordinator.setSafeModeLevel(level)
    }

    /// What the Safe Mode list offers for the connection on screen, or nil with no session behind it.
    var safeModeStatus: SafeModeStatus? {
        workspaces.selected?.sessionState?.coordinator.safeModeStatus
    }

    @objc func switchSessionContext(_ sender: Any?) {
        guard let selection = (sender as? NSMenuItem)?.representedObject as? SessionContextSelection,
              let coordinator = commandActions?.coordinator else { return }
        Task { await coordinator.switchSessionContext(id: selection.contextId, to: selection.value) }
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

    @objc func copyObjectsToDatabase(_ sender: Any?) {
        commandActions?.copyObjectsToAnotherDatabase()
    }

    @objc func duplicateCurrentDatabase(_ sender: Any?) {
        commandActions?.duplicateCurrentDatabase()
    }

    @objc func showTableStructure(_ sender: Any?) {
        commandActions?.showTableStructure()
    }

    @objc func editViewDefinition(_ sender: Any?) {
        commandActions?.editViewDefinition()
    }

    @objc func showObjectDDL(_ sender: Any?) {
        commandActions?.showObjectDDL()
    }

    @objc func copyObjectDDL(_ sender: Any?) {
        commandActions?.copyObjectDDL()
    }

    @objc func refreshMaterializedView(_ sender: Any?) {
        commandActions?.refreshMaterializedView()
    }

    @objc func editObjectComment(_ sender: Any?) {
        commandActions?.editObjectComment()
    }

    @objc func runMaintenanceOperation(_ sender: Any?) {
        guard let operation = (sender as? NSMenuItem)?.representedObject as? PluginMaintenanceOperation
        else { return }
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
