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
        workspace.panes.tabStrip.rootView = AnyView(buildTabStripView(for: workspace))
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
    @ViewBuilder
    private func buildTabStripView(for workspace: ConnectionWorkspace) -> some View {
        if let sessionState = workspace.sessionState {
            EditorTabStrip(
                tabManager: sessionState.tabManager,
                containerTarget: workspace.connection.flatMap {
                    PluginManager.shared.containerSwitchTarget(for: $0.type)
                },
                onClose: { [weak workspace] id in
                    workspace?.sessionState?.coordinator.commandActions?.closeTab(id: id)
                },
                onCloseOthers: { [weak workspace] id in
                    workspace?.sessionState?.coordinator.commandActions?.closeOtherTabs(anchoredOn: id)
                },
                onCloseAll: { [weak workspace] in
                    workspace?.sessionState?.coordinator.commandActions?.closeAllTabs()
                },
                onNewTab: { [weak workspace] in
                    workspace?.sessionState?.coordinator.commandActions?.newTab()
                }
            )
        } else {
            Color.clear
        }
    }
}
