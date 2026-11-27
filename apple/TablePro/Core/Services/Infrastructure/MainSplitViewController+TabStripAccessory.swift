//
//  MainSplitViewController+TabStripAccessory.swift
//  TablePro
//

import AppKit
import Combine

internal extension MainSplitViewController {
    // At construction, because a window that joins a tab group without activating never runs its appearance lifecycle.
    func installTabStripAccessory(on window: NSWindow) {
        guard !window.titlebarAccessoryViewControllers.contains(where: { $0 === tabStripAccessory }) else { return }
        tabStripAccessory.setBandVisible(false)
        window.addTitlebarAccessoryViewController(tabStripAccessory)
        showSelectedTabStrip()
    }

    func refreshTabStripPane(of workspace: ConnectionWorkspace) {
        let pane = workspace.panes.tabStrip
        guard let sessionState = workspace.sessionState else {
            pane.unbind()
            return
        }
        pane.bind(
            tabManager: sessionState.tabManager,
            execution: TabExecutionObservation(owner: sessionState.coordinator),
            target: workspace.connection.flatMap { PluginManager.shared.containerSwitchTarget(for: $0.type) },
            commands: makeTabCommands(for: workspace, sessionState: sessionState)
        )
    }

    func showSelectedTabStrip() {
        tabStripAccessory.show(workspaces.selected?.panes.tabStrip)
        applyTabStripVisibility()
    }

    // Re-arms on every call: the first arm runs from `TabWindowController.init`, before the connection has a session.
    func applyTabStripVisibility() {
        let tabCount = workspaces.selected?.sessionState?.tabManager.visibleTabs.count ?? 0
        tabStripAccessory.setBandVisible(
            ConnectionWindowPaneResolver.showsTabStrip(
                for: currentPane,
                tabCount: tabCount,
                contentMode: contentMode
            )
        )
        armTabStripObservation()
    }

    // The generation is carried because an arm that already fired cannot be recalled and must fail its own guard.
    private func armTabStripObservation() {
        let manager = workspaces.selected?.sessionState?.tabManager
        let identity = manager.map(ObjectIdentifier.init)
        guard !tabStripObservationIsArmed || identity != tabStripObservedManager else { return }

        tabStripObservationGeneration += 1
        tabStripObservationIsArmed = true
        tabStripObservedManager = identity
        let generation = tabStripObservationGeneration

        guard let manager = workspaces.selected?.sessionState?.tabManager else { return }
        var lastCount = manager.visibleTabs.count
        tabStripObservation = manager.onMainActorChange { [weak self] in
            guard let self, generation == self.tabStripObservationGeneration else { return }
            let current = manager.visibleTabs.count
            guard current != lastCount else { return }
            lastCount = current
            self.tabStripObservationIsArmed = false
            self.applyTabStripVisibility()
        }
    }

    // The strip holds the field, so the command edits the selected tab where it is drawn.
    @objc func renameEditorTab(_ sender: Any?) {
        guard let workspace = workspaces.selected,
              let id = workspace.sessionState?.tabManager.selectedTab?.id
        else { return }
        workspace.panes.tabStrip.stripView.beginRename(id)
    }

    var canRenameSelectedEditorTab: Bool {
        guard let manager = workspaces.selected?.sessionState?.tabManager,
              let id = manager.selectedTab?.id
        else { return false }
        return manager.canRenameTab(id: id)
    }

    private static func tabStripContains(screenPoint: NSPoint) -> Bool {
        let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        guard let window = NSApp.window(withWindowNumber: number),
              let split = window.contentViewController as? MainSplitViewController,
              !split.tabStripAccessory.isHidden
        else { return false }
        let band = split.tabStripAccessory.view
        return window.convertToScreen(band.convert(band.bounds, to: nil)).contains(screenPoint)
    }

    // The workspace is held weakly: it owns the pane these closures live in.
    private func makeTabCommands(
        for workspace: ConnectionWorkspace,
        sessionState: SessionStateFactory.SessionState
    ) -> EditorTabCommands {
        let manager = sessionState.tabManager
        return EditorTabCommands(
            connectionId: workspace.connectionId,
            activate: { [weak manager] id in
                guard let manager, manager.selectedTabId != id else { return }
                TabSwitchTracer.shared.requestSwitch(.tabStrip, to: id)
                manager.selectedTabId = id
            },
            newTab: { [weak workspace] in
                workspace?.sessionState?.coordinator.commandActions?.newTab()
            },
            keepOpen: { [weak manager] id in
                manager?.promotePreviewTab(id: id)
                if #available(macOS 14.0, *) {
                    FeatureTipSignals.tableKeptOpen()
                }
            },
            canKeepOpen: { [weak manager] id in manager?.canPromotePreviewTab(id: id) ?? false },
            isPinned: { [weak manager] id in manager?.isPinned(id: id) ?? false },
            setPinned: { [weak manager] id, pinned in manager?.setPinned(pinned, id: id) },
            canRename: { [weak manager] id in manager?.canRenameTab(id: id) ?? false },
            renameSeed: { [weak manager] id in
                manager?.tabs.first { $0.id == id }.map {
                    EditorTabRenameSeed(text: $0.title, placeholder: $0.automaticName)
                }
            },
            beginRename: { [weak workspace] id in
                workspace?.panes.tabStrip.stripView.beginRename(id)
            },
            rename: { [weak manager] id, text in
                manager?.renameTab(id: id, to: text)
                return manager?.tabs.first { $0.id == id }?.title
            },
            close: { [weak workspace] id in
                workspace?.sessionState?.coordinator.commandActions?.closeTab(id: id)
            },
            closeOthers: { [weak workspace] id in
                workspace?.sessionState?.coordinator.commandActions?.closeOtherTabs(anchoredOn: id)
            },
            canCloseOthers: { [weak workspace] id in
                workspace?.sessionState?.coordinator.commandActions?.canCloseOtherTabs(anchoredOn: id) ?? false
            },
            closeAll: { [weak workspace] in
                workspace?.sessionState?.coordinator.commandActions?.closeAllTabs()
            },
            canCloseAll: { [weak workspace] in
                workspace?.sessionState?.coordinator.commandActions?.canCloseAllTabs ?? false
            },
            moveTab: { [weak manager] id, destination in manager?.moveTab(id: id, to: destination) },
            canMove: { [weak manager] id, offset in manager?.canMoveTab(id: id, by: offset) ?? false },
            moveBy: { [weak manager] id, offset in manager?.moveTab(id: id, by: offset) },
            tearOff: { [weak workspace] id, dropPoint in
                guard let connectionId = workspace?.connectionId else { return }
                WindowManager.shared.openTabInNewWindow(connectionId: connectionId, tabId: id, droppedAt: dropPoint)
            },
            canTearOff: { [weak workspace] id in
                guard let workspace,
                      let sessionState = workspace.sessionState,
                      let tab = sessionState.tabManager.tabs.first(where: { $0.id == id })
                else { return false }
                return EditorTabDetachPolicy.canDetach(
                    tabType: tab.tabType,
                    tabCount: sessionState.tabManager.tabs.count,
                    hasUnsavedWork: sessionState.coordinator.hasUnsavedWork(forTab: id),
                    isBusy: sessionState.coordinator.holdsWorkThatCannotMove(tab),
                    // Not the driver handle, which stays installed through a reconnect and after the monitor gives up.
                    isConnected: DatabaseManager.shared.activeSessions[workspace.connectionId]?
                        .reportedStatus.isConnected == true
                )
            },
            receiveTab: { [weak workspace] id, index in
                guard let workspace else { return false }
                return WindowManager.shared.moveTab(id, into: workspace, at: index)
            },
            isOverTabStrip: { Self.tabStripContains(screenPoint: $0) },
            // The selection is left alone: selecting first would judge the tab against the grid edits it replaced.
            moveToConnection: { [weak self] id in
                self?.presentMoveTabPicker(tabId: id)
            },
            offersMoveToConnection: { [weak manager] id in
                manager?.tabs.first { $0.id == id }?.tabType == .query
            },
            canMoveToConnection: { [weak workspace] id in
                workspace?.sessionState?.coordinator.canMoveTabToConnection(id) ?? false
            }
        )
    }
}
