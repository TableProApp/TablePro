//
//  WorkspaceCloseAction.swift
//  TablePro
//

import AppKit
import Foundation
import os

/// The one path a user-requested close of a connections-strip entry takes, from the strip's
/// contextual menu, a middle click, or Close while the strip holds the keyboard.
///
/// An entry is one container of one connection, and it is open until it is closed, so the close
/// command on it takes that container: its tabs go, its entry goes, and the connection stays with
/// everything it has open elsewhere. A connection's last entry is the connection itself, so closing
/// that one is `ConnectionCloseAction`; otherwise closing the row a user is looking at would leave
/// a hosted connection with nothing in the strip to bring it back.
///
/// The strip's close used to take the whole connection whichever row it was invoked on, because a
/// row had no lifetime of its own: membership was derived from the tabs, so closing one container's
/// tabs left the row exactly where it was and the command read as doing nothing (#2115).
@MainActor
internal enum WorkspaceCloseAction {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "WorkspaceRail")

    internal enum Scope: Equatable {
        case container
        case connection
    }

    /// `entryCount` is how many entries the strip lists for this connection.
    internal static func scope(entryCount: Int) -> Scope {
        entryCount > 1 ? .container : .connection
    }

    /// The entry that takes the closed one's place, so closing lands on a neighbour the way closing
    /// a tab does, rather than on whatever the connection happened to browse last.
    internal static func neighbour(in containers: [String], closing container: String) -> String? {
        guard let index = containers.firstIndex(of: container) else { return containers.first }
        var remaining = containers
        remaining.remove(at: index)
        guard !remaining.isEmpty else { return nil }
        return remaining.indices.contains(index) ? remaining[index] : remaining.last
    }

    internal static func close(_ workspace: WorkspaceID) async {
        let containers = listedContainers(of: workspace.connectionId)
        Self.logger.info(
            """
            close container=\(workspace.container, privacy: .public) \
            listed=[\(containers.joined(separator: " "), privacy: .public)] \
            scope=\(String(describing: scope(entryCount: containers.count)), privacy: .public)
            """
        )
        guard scope(entryCount: containers.count) == .container, !workspace.container.isEmpty else {
            await ConnectionCloseAction.close(connectionId: workspace.connectionId)
            return
        }
        guard let hosted = WindowManager.shared.workspace(for: workspace.connectionId) else {
            Self.logger.error("close has no hosted workspace container=\(workspace.container, privacy: .public)")
            return
        }

        let coordinator = hosted.sessionState?.coordinator
        let victims = tabs(in: workspace.container, of: coordinator)
        guard await confirm(victims, coordinator: coordinator, revealing: workspace) else {
            Self.logger.info("close cancelled at the save prompt container=\(workspace.container, privacy: .public)")
            return
        }
        guard await browseAway(from: workspace, among: containers, coordinator: coordinator) else {
            Self.logger.error(
                "close stopped: could not leave container=\(workspace.container, privacy: .public)"
            )
            return
        }

        if !victims.isEmpty {
            coordinator?.closeTabsByUser(ids: victims.map(\.id))
        }
        hosted.closeContainer(workspace.container)
        landOnRemainingTab(after: workspace, among: containers, coordinator: coordinator)
        Self.logger.info(
            """
            close done container=\(workspace.container, privacy: .public) \
            tabsClosed=\(victims.count, privacy: .public) \
            opened=[\(hosted.openedContainers.sorted().joined(separator: " "), privacy: .public)]
            """
        )
    }

    /// Shown, then asked, for the same reason a connection close reveals itself first: an alert
    /// about work the user cannot see names tabs they have no way to look at before answering.
    /// Selecting one of the victims is also what makes Save save a victim. It runs only when there
    /// is something to confirm, because raising a background connection's window and moving its tab
    /// selection is a side effect no one asked for when the close has nothing to lose.
    private static func confirm(
        _ victims: [QueryTab],
        coordinator: MainContentCoordinator?,
        revealing workspace: WorkspaceID
    ) async -> Bool {
        guard let actions = coordinator?.commandActions, !victims.isEmpty else { return true }
        guard actions.hasUnsavedWork(among: victims) else { return true }
        reveal(workspace, coordinator: coordinator)
        return await actions.confirmDiscardingUnsavedWork(victims: victims)
    }

    /// Leaves the container before it stops being listed, and only when it is the one being browsed.
    /// Every other entry already shows the container it names, and moving the cursor for them would
    /// switch the database out from under work the user did not touch.
    ///
    /// Returning false stops the close: a switch can fail, on a database the user has no rights to,
    /// and removing the entry anyway would leave the window browsing a container the strip no longer
    /// lists. The driver's own error is already on screen, and nothing has been closed yet.
    private static func browseAway(
        from workspace: WorkspaceID,
        among containers: [String],
        coordinator: MainContentCoordinator?
    ) async -> Bool {
        guard let coordinator else { return true }
        guard WorkspaceRailStore.browsedWorkspace(for: workspace.connectionId) == workspace else { return true }
        guard let next = neighbour(in: containers, closing: workspace.container) else { return true }
        await coordinator.switchContainer(to: next)
        return WorkspaceRailStore.browsedWorkspace(for: workspace.connectionId)?.container == next
    }

    /// The tab the connection last used in the container it landed in, once the closed container's
    /// own tabs are gone.
    private static func landOnRemainingTab(
        after workspace: WorkspaceID,
        among containers: [String],
        coordinator: MainContentCoordinator?
    ) {
        guard let coordinator, let next = neighbour(in: containers, closing: workspace.container) else { return }
        guard WorkspaceRailStore.browsedWorkspace(for: workspace.connectionId)?.container == next else { return }
        coordinator.selectTab(inContainer: next)
    }

    private static func listedContainers(of connectionId: UUID) -> [String] {
        WorkspaceRailStore.entries
            .filter { $0.workspace.connectionId == connectionId }
            .map(\.container)
    }

    private static func tabs(in container: String, of coordinator: MainContentCoordinator?) -> [QueryTab] {
        guard let coordinator else { return [] }
        let target = PluginManager.shared.containerSwitchTarget(for: coordinator.connection.type)
        return coordinator.tabManager.tabs.filter {
            WorkspaceAnchoring.containerName(of: $0, target: target) == container
        }
    }

    private static func reveal(_ workspace: WorkspaceID, coordinator: MainContentCoordinator?) {
        if let window = WindowManager.shared.window(for: workspace.connectionId) {
            if let group = window.tabGroup, group.selectedWindow !== window {
                group.selectedWindow = window
            }
            window.makeKeyAndOrderFront(nil)
            (window.contentViewController as? MainSplitViewController)?
                .workspaces.select(workspace.connectionId)
        }
        coordinator?.selectTab(inContainer: workspace.container)
    }
}
