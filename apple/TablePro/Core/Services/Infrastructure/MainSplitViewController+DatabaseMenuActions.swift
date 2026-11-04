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

    // The window owns switching because a disconnected workspace has no command actions.
    func openConnectionSwitcher() {
        view.window?.makeFirstResponder(nil)
        switcherPresenter.present(
            from: view.window,
            anchoredTo: MainWindowToolbar.connection,
            hiddenBy: toolbarOwner?.visibility,
            subject: .connection,
            contentSize: ConnectionSwitcherPopover.contentSize
        ) { [selectedConnectionId] dismiss in
            ConnectionSwitcherPopover(
                dismiss: dismiss,
                currentConnectionId: selectedConnectionId,
                purpose: .switchConnection
            )
        }
    }

    @objc func moveTabToConnection(_ sender: Any?) {
        guard let tabId = workspaces.selected?.sessionState?.coordinator.tabManager.selectedTab?.id else { return }
        presentMoveTabPicker(tabId: tabId)
    }

    var canMoveSelectedTabToConnection: Bool {
        guard let coordinator = workspaces.selected?.sessionState?.coordinator,
              let tabId = coordinator.tabManager.selectedTab?.id else { return false }
        return coordinator.canMoveTabToConnection(tabId)
    }

    // Capture the source now because the selected workspace can change before the pick.
    func presentMoveTabPicker(tabId: UUID) {
        guard let source = workspace(holding: tabId),
              let coordinator = source.sessionState?.coordinator,
              let tab = coordinator.tabManager.tabs.first(where: { $0.id == tabId }),
              coordinator.canMoveTabToConnection(tabId)
        else { return }
        let sourceConnectionId = source.connectionId
        let title = tab.title
        view.window?.makeFirstResponder(nil)
        switcherPresenter.present(
            from: view.window,
            anchoredTo: MainWindowToolbar.connection,
            hiddenBy: toolbarOwner?.visibility,
            subject: .moveTab(tabId),
            contentSize: ConnectionSwitcherPopover.contentSize
        ) { dismiss in
            ConnectionSwitcherPopover(
                dismiss: dismiss,
                currentConnectionId: sourceConnectionId,
                purpose: .moveTab(title: title, onPick: { [weak self] targetConnectionId in
                    guard let self else { return }
                    WindowManager.shared.moveQueryTab(
                        tabId: tabId,
                        from: sourceConnectionId,
                        in: self,
                        to: targetConnectionId
                    )
                })
            )
        }
    }

    private func workspace(holding tabId: UUID) -> ConnectionWorkspace? {
        workspaces.workspaces.first { workspace in
            workspace.sessionState?.tabManager.tabs.contains { $0.id == tabId } == true
        }
    }

    @objc func openContainerSwitcher(_ sender: Any?) {
        commandActions?.openDatabaseSwitcher()
    }

    // The full chooser stays useful when the schema submenu cannot fit every entry.
    @objc func openSchemaSwitcher(_ sender: Any?) {
        commandActions?.openScopeSwitcher(.schema)
    }

    @objc func createSchema(_ sender: Any?) {
        guard let coordinator = commandActions?.coordinator, coordinator.admitsSheetCommand() else { return }
        coordinator.createSchema(database: nil)
    }

    // The browsed schema, for a sidebar shape that draws no schema row to right-click.
    @objc func editCurrentSchema(_ sender: Any?) {
        guard let coordinator = commandActions?.coordinator,
              coordinator.admitsSheetCommand(),
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

    // Agent mode may never mount browse command actions, so use the workspace coordinator.
    @objc func setSafeModeLevel(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let level = SafeModeLevel(rawValue: raw) else { return }
        workspaces.selected?.sessionState?.coordinator.setSafeModeLevel(level)
    }

    // What the Safe Mode list offers for the connection on screen, or nil with no session behind it.
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

    @objc func createNewSequence(_ sender: Any?) {
        commandActions?.createSequence()
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

    @objc func searchDatabase(_ sender: Any?) {
        commandActions?.searchDatabase()
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

    @objc func setSequenceNextValue(_ sender: Any?) {
        commandActions?.setSequenceNextValue()
    }

    @objc func editSequence(_ sender: Any?) {
        commandActions?.editSequence()
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

    @objc func buildJoinQuery(_ sender: Any?) {
        commandActions?.buildJoinQuery()
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

    @objc func showTableHealth(_ sender: Any?) {
        commandActions?.showTableHealth()
    }
}
