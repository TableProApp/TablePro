//
//  MainContentCommandActions+Switchers.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

internal extension MainContentCommandActions {
    func openDatabaseSwitcher() {
        openScopeSwitcher(nil)
    }

    /// The one way into the container chooser, for either scope. It used to have two, and the
    /// second skipped the session gate the first applies: the centred toolbar chip opened the
    /// chooser over a session the health monitor had given up on, while the button 200pt away and
    /// the menu command were both correctly disabled. A chooser with one entry point cannot drift
    /// from itself.
    ///
    /// `nil` means the engine's primary container, which is what a command with no scope named can
    /// mean.
    func openScopeSwitcher(_ target: ContainerSwitchTarget?) {
        guard let coordinator, canSwitchContainer(target, on: coordinator) else { return }
        /// Clearing first responder is what lets the popover's search field take focus.
        coordinator.contentWindow?.makeFirstResponder(nil)
        presentDatabaseSwitcher(on: coordinator, target: target)
    }

    private func canSwitchContainer(
        _ target: ContainerSwitchTarget?,
        on coordinator: MainContentCoordinator
    ) -> Bool {
        let type = coordinator.connection.type
        guard MainWindowToolbar.hasLiveSession(coordinator.toolbarState.connectionState) else { return false }
        guard PluginManager.shared.connectionMode(for: type) != .fileBased else { return false }
        guard let target else { return PluginManager.shared.supportsContainerSwitching(for: type) }
        return PluginManager.shared.switchableContainers(for: type).contains(target)
    }

    func openQuickSwitcher() {
        coordinator?.showQuickSwitcher()
    }

    func showColumnJump() {
        guard canJumpToColumn else { return }
        coordinator?.showColumnJump()
    }

    /// The window presents this one. It is a window command wherever it is invoked from, and
    /// keeping a copy of the presentation here would give one window two owners for one popover.
    func openConnectionSwitcher() {
        coordinator?.splitViewController?.openConnectionSwitcher()
    }

    func dismissScopeSwitcher() {
        coordinator?.switcherPresenter?.dismiss()
    }

    /// Anchored to the Database item, which is the capsule the user pressed. It is a top-level
    /// centred item, so it anchors on its own capsule, measured within 2pt of where the old subitem
    /// anchor landed at a 1200pt window. Clipped, AppKit anchors it on the clipped-items indicator
    /// itself; hidden by the context, the presenter takes the floating panel.
    private func presentDatabaseSwitcher(on coordinator: MainContentCoordinator, target: ContainerSwitchTarget?) {
        coordinator.switcherPresenter?.present(
            from: coordinator.contentWindow,
            anchoredTo: MainWindowToolbar.database,
            hiddenBy: coordinator.splitViewController?.toolbarOwner?.visibility,
            subject: .container(target),
            contentSize: DatabaseSwitcherPopover.contentSize
        ) { dismiss in
            DatabaseSwitcherPopoverHost(coordinator: coordinator, target: target, dismiss: dismiss)
        }
    }
}
