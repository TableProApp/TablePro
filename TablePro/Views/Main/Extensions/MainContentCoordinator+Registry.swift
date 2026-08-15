//
//  MainContentCoordinator+Registry.swift
//  TablePro
//

import AppKit
import Foundation

extension MainContentCoordinator {
    static func allActiveCoordinators() -> [MainContentCoordinator] {
        Array(activeCoordinators.values)
    }

    static func coordinator(for windowId: UUID) -> MainContentCoordinator? {
        activeCoordinators.values.first { $0.windowId == windowId }
    }

    /// The coordinator the window is currently showing. Every connection the window hosts has a
    /// coordinator whose `contentWindow` is this window, so matching on that alone returned an
    /// arbitrary one of them and let Cmd+W, Cmd+T and menu validation act on a connection the
    /// user was not looking at.
    static func coordinator(forWindow window: NSWindow) -> MainContentCoordinator? {
        guard let host = window.contentViewController as? MainSplitViewController else {
            return activeCoordinators.values.first { $0.contentWindow === window }
        }
        return host.workspaces.selected?.sessionState?.coordinator
    }

    static func hasAnyUnsavedChanges() -> Bool {
        activeCoordinators.values.contains { $0.hasAnyUnsavedWork() }
    }

    /// Disconnecting ends the session behind every window on the connection, so what is at risk is
    /// never just the window the command came from. The rail and the connection list can both fire
    /// it for a connection whose windows are all in the background.
    static func hasUnsavedWork(forConnection connectionId: UUID) -> Bool {
        activeCoordinators.values
            .filter { $0.connectionId == connectionId }
            .contains { $0.hasAnyUnsavedWork() }
    }

    static func hasRunningQuery(forConnection connectionId: UUID) -> Bool {
        activeCoordinators.values
            .filter { $0.connectionId == connectionId }
            .contains { $0.toolbarState.isExecuting }
    }

    static func allTabs(for connectionId: UUID) -> [QueryTab] {
        activeCoordinators.values
            .filter { $0.connectionId == connectionId }
            .flatMap { $0.tabManager.tabs }
    }

    static func coordinator(
        forConnection connectionId: UUID,
        tabMatching predicate: (QueryTab) -> Bool
    ) -> MainContentCoordinator? {
        activeCoordinators.values.first { coordinator in
            coordinator.connectionId == connectionId
                && coordinator.tabManager.tabs.contains(where: predicate)
        }
    }

    /// The window showing a workspace's own work.
    ///
    /// A rail row exists because tabs live in that container, so activating it has to land on one
    /// of them. Raising the connection's most recent window instead lands on whatever tab was last
    /// focused, which for a second container is the wrong work entirely: the row paints as selected
    /// while the window subtitle names another database.
    ///
    /// Returns nil when the container holds no tab, which is the browse-cursor-only row. Moving the
    /// cursor is the whole of the correct behaviour there.
    static func window(showing workspace: WorkspaceID, target: ContainerSwitchTarget?) -> NSWindow? {
        let candidates = activeCoordinators.values
            .filter { $0.connectionId == workspace.connectionId }
            .filter { coordinator in
                coordinator.tabManager.tabs.contains { tab in
                    WorkspaceAnchoring.containerName(of: tab, target: target) == workspace.container
                }
            }
            .compactMap(\.contentWindow)

        guard !candidates.isEmpty else { return nil }
        let lastFocused = WindowLifecycleMonitor.shared.mostRecentWindow(for: workspace.connectionId)
        return candidates.first { $0 === lastFocused } ?? candidates.first
    }
}
