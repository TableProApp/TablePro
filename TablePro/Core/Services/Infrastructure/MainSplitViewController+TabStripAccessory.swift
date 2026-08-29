//
//  MainSplitViewController+TabStripAccessory.swift
//  TablePro
//

import AppKit
import SwiftUI

internal extension MainSplitViewController {
    /// Installed from `TabWindowController.init`, right after the content view controller is
    /// assigned, rather than from `viewWillAppear`. A window that joins a tab group without ever
    /// being activated never runs its appearance lifecycle, so a band added there would be missing
    /// from every background tab until the user clicked it. That is the same shape as the blank
    /// window title CLAUDE.md records, and the fix is the same: do it at construction.
    func installTabStripAccessory(on window: NSWindow) {
        guard !window.titlebarAccessoryViewControllers.contains(where: { $0 === tabStripAccessory }) else { return }
        tabStripAccessory.setBandVisible(false)
        window.addTitlebarAccessoryViewController(tabStripAccessory)
        showSelectedTabStrip()
    }

    /// The strip is built per connection like the other three panes, so a connection the user is
    /// not looking at keeps its own strip rather than rebuilding it on every switch.
    func refreshTabStripPane(of workspace: ConnectionWorkspace) {
        workspace.panes.tabStrip.rootView = buildTabStripView(for: workspace)
    }

    func showSelectedTabStrip() {
        tabStripAccessory.show(workspaces.selected?.panes.tabStrip)
        applyTabStripVisibility()
    }

    /// Re-arms on every call, which is what makes this safe to drive from anywhere. The first arm
    /// a window makes is worthless on its own: it runs from `TabWindowController.init`, before the
    /// connection has a session, so the tracking closure reads through a nil `sessionState` and
    /// registers a dependency on nothing. Only the call that follows the session coming up sees a
    /// real `tabManager` to observe, and there is no single moment in the lifecycle that is
    /// reliably that call.
    func applyTabStripVisibility() {
        let tabCount = workspaces.selected?.sessionState?.tabManager.tabs.count ?? 0
        tabStripAccessory.setBandVisible(
            ConnectionWindowPaneResolver.showsTabStrip(for: currentPane, tabCount: tabCount)
        )
        armTabStripObservation()
    }

    /// `withObservationTracking` fires once per registration and cannot be cancelled, so something
    /// has to re-register and nothing may register twice. `applyTabStripVisibility()` runs on every
    /// phase change and every workspace switch, which would otherwise leave a live arm behind each
    /// time and wake all of them on the next tab change. An arm is therefore made only when there
    /// is none, or when the connection on screen changed and the live one is watching the previous
    /// connection's tab manager: `workspaces.selected` is not itself observable, so a switch can
    /// never reach the closure on its own.
    ///
    /// The generation is still carried, because an arm that has already fired cannot be recalled
    /// and must fail its own guard rather than act on a window that has moved on.
    private func armTabStripObservation() {
        let manager = workspaces.selected?.sessionState?.tabManager
        let identity = manager.map(ObjectIdentifier.init)
        guard !tabStripObservationIsArmed || identity != tabStripObservedManager else { return }

        tabStripObservationGeneration += 1
        tabStripObservationIsArmed = true
        tabStripObservedManager = identity
        let generation = tabStripObservationGeneration

        withObservationTracking { [weak self] in
            _ = self?.workspaces.selected?.sessionState?.tabManager.tabs.count
        } onChange: { [weak self] in
            /// Observation reports the change before it lands, so the count is read on the next
            /// turn of the main actor rather than in the callback.
            Task { @MainActor [weak self] in
                guard let self, generation == self.tabStripObservationGeneration else { return }
                self.tabStripObservationIsArmed = false
                self.applyTabStripVisibility()
            }
        }
    }

    /// `commandActions` is read at click time rather than captured, because it only exists once
    /// the detail pane has appeared and this strip is built alongside that pane, not after it.
    /// The workspace is held weakly: it owns the hosting controller these closures live in.
    ///
    /// The command set is handed to the pane's interaction object rather than to the SwiftUI view,
    /// because the view is no longer what receives a press. AppKit owns the pointer over the
    /// strip and reaches the app through exactly these closures.
    private func buildTabStripView(for workspace: ConnectionWorkspace) -> AnyView {
        guard let sessionState = workspace.sessionState else { return AnyView(Color.clear) }
        let interaction = workspace.panes.tabStrip.interaction
        configure(interaction, for: workspace, sessionState: sessionState)
        return AnyView(
            EditorTabStrip(
                tabManager: sessionState.tabManager,
                interaction: interaction,
                containerTarget: workspace.connection.flatMap {
                    PluginManager.shared.containerSwitchTarget(for: $0.type)
                },
                onNewTab: { [weak workspace] in
                    workspace?.sessionState?.coordinator.commandActions?.newTab()
                }
            )
        )
    }

    private func configure(
        _ interaction: EditorTabStripInteraction,
        for workspace: ConnectionWorkspace,
        sessionState: SessionStateFactory.SessionState
    ) {
        let manager = sessionState.tabManager
        let target = workspace.connection.flatMap { PluginManager.shared.containerSwitchTarget(for: $0.type) }
        interaction.commands = EditorTabCommands(
            activate: { [weak manager] id in manager?.selectedTabId = id },
            keepOpen: { [weak manager] id in manager?.promotePreviewTab(id: id) },
            canKeepOpen: { [weak manager] id in manager?.canPromotePreviewTab(id: id) ?? false },
            close: { [weak workspace] id in
                workspace?.sessionState?.coordinator.commandActions?.closeTab(id: id)
            },
            closeOthers: { [weak workspace] id in
                workspace?.sessionState?.coordinator.commandActions?.closeOtherTabs(anchoredOn: id)
            },
            closeAll: { [weak workspace] in
                workspace?.sessionState?.coordinator.commandActions?.closeAllTabs()
            },
            moveTab: { [weak manager] id, destination in manager?.moveTab(id: id, to: destination) },
            canMove: { [weak manager] id, offset in manager?.canMoveTab(id: id, by: offset) ?? false },
            moveBy: { [weak manager] id, offset in manager?.moveTab(id: id, by: offset) },
            tearOff: { [weak workspace] id in
                guard let connectionId = workspace?.connectionId else { return }
                WindowManager.shared.openTabInNewWindow(connectionId: connectionId, tabId: id)
            },
            canTearOff: { [weak workspace] id in
                guard let workspace,
                      let sessionState = workspace.sessionState
                else { return false }
                return EditorTabDetachPolicy.canDetach(
                    tabCount: sessionState.tabManager.tabs.count,
                    hasUnsavedWork: sessionState.coordinator.hasUnsavedWork(forTab: id),
                    isBusy: sessionState.coordinator.tabExecution.isExecuting(id),
                    isConnected: DatabaseManager.shared.activeSessions[workspace.connectionId]?.driver != nil
                )
            },
            /// The resolver's description, not the drawn title: a table tab carries its database
            /// and schema there even when the short title is unique, and the tooltip is where a
            /// truncated or duplicated name is told apart.
            tooltip: { [weak manager] id in
                guard let manager, let tab = manager.tabs.first(where: { $0.id == id }) else { return "" }
                let description = EditorTabLabelResolver.resolve(tabs: manager.tabs, target: target)[id]?
                    .description ?? tab.title
                guard tab.isPreview else { return description }
                return String(
                    format: String(localized: "%@\nPreview tab. Double-click to keep it open."),
                    description
                )
            }
        )
    }
}
