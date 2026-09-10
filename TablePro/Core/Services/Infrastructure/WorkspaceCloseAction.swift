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

    /// A tab is closed by the window that owns it. Sending every id to one coordinator drops the
    /// ones it has never heard of, which is exactly the tabs that were torn off into another window.
    private static func closeTabs(_ ids: [UUID], across coordinators: [MainContentCoordinator]) {
        for coordinator in coordinators {
            let owned = ids.filter { id in coordinator.tabManager.tabs.contains { $0.id == id } }
            guard !owned.isEmpty else { continue }
            coordinator.closeTabsByUser(ids: owned)
        }
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
        /// Every window hosting the connection. A tab torn off into its own window can be the
        /// container's only remaining tab, and closing the entry from the window that happens to
        /// answer first would leave that tab open under an entry the user just closed.
        let hostedWorkspaces = WindowManager.shared.workspaces(for: workspace.connectionId)
        guard let hosted = hostedWorkspaces.first else {
            Self.logger.error("close has no hosted workspace container=\(workspace.container, privacy: .public)")
            return
        }

        let coordinators = hostedWorkspaces.compactMap { $0.sessionState?.coordinator }
        let coordinator = coordinators.first
        let victims = coordinators.flatMap { tabs(in: workspace.container, of: $0) }
        /// Where the user was before the alert. Confirming reveals the work at risk, which switches
        /// the window to that connection and selects one of the tabs, and an answer that closes
        /// nothing has to put all of that back: leaving the user on a connection they did not ask
        /// for, with the entry still listed, is a close that reads as a switch.
        let wasShowing = WindowManager.shared.shownConnection(besides: workspace.connectionId)
        guard let closable = await confirm(victims, across: coordinators, revealing: workspace) else {
            WindowManager.shared.show(wasShowing, inWindowHosting: workspace.connectionId)
            Self.logger.info("close cancelled at the save prompt container=\(workspace.container, privacy: .public)")
            return
        }
        /// A tab whose work the save could not take keeps the container open, because it is still
        /// work in it. Closing the entry regardless would destroy exactly what the alert said would
        /// stay, which is the promise the wording makes.
        guard closable.isSuperset(of: Set(victims.map(\.id))) else {
            closeTabs(victims.map(\.id).filter { closable.contains($0) }, across: coordinators)
            WindowManager.shared.show(wasShowing, inWindowHosting: workspace.connectionId)
            Self.logger.info(
                """
                close kept container=\(workspace.container, privacy: .public) \
                unsaveable=\(victims.count - closable.count, privacy: .public)
                """
            )
            return
        }
        /// The entry goes now, before the connection leaves the container, because leaving it is a
        /// reconnect and a schema reload on every engine that cannot change database on a live
        /// connection: waiting for that left the row the user just closed sitting there for seconds
        /// while the window loaded somewhere else. `beginClosing` is what lets the strip drop the
        /// browse cursor's own row early, and the cursor follows underneath.
        if !victims.isEmpty {
            closeTabs(victims.map(\.id), across: coordinators)
        }
        for hostedWorkspace in hostedWorkspaces {
            hostedWorkspace.closeContainer(workspace.container)
        }
        for hostedWorkspace in hostedWorkspaces {
            hostedWorkspace.beginClosing(workspace.container)
        }
        Self.logger.info(
            """
            close done container=\(workspace.container, privacy: .public) \
            tabsClosed=\(victims.count, privacy: .public) \
            opened=[\(hosted.openedContainers.sorted().joined(separator: " "), privacy: .public)]
            """
        )

        let left = await browseAway(from: workspace, among: containers, coordinator: coordinator)
        for hostedWorkspace in hostedWorkspaces {
            hostedWorkspace.endClosing()
        }
        guard left else {
            /// The connection never left, so the container is open again: it is where the next tab
            /// still opens, and a strip that did not list it would be lying about where the user is.
            /// The driver's own error is already on screen.
            for hostedWorkspace in hostedWorkspaces {
                hostedWorkspace.openContainer(workspace.container)
            }
            WindowManager.shared.show(wasShowing, inWindowHosting: workspace.connectionId)
            Self.logger.error(
                "close could not leave container=\(workspace.container, privacy: .public)"
            )
            return
        }

        /// Read again rather than reusing the list from before the switch: a table opened while the
        /// reconnect ran anchors the container all over again, and the entry would come back with
        /// one stray tab under it. A tab that new has nothing to lose.
        let opened = coordinators.flatMap { tabs(in: workspace.container, of: $0) }
        if !opened.isEmpty {
            closeTabs(opened.map(\.id), across: coordinators)
            for hostedWorkspace in hostedWorkspaces {
                hostedWorkspace.closeContainer(workspace.container)
            }
        }
        landOnRemainingTab(after: workspace, among: containers, coordinator: coordinator)
    }

    /// Shown, then asked, for the same reason a connection close reveals itself first: an alert
    /// about work the user cannot see names tabs they have no way to look at before answering.
    /// Selecting one of the victims is also what makes Save save a victim. It runs only when there
    /// is something to confirm, because raising a background connection's window and moving its tab
    /// selection is a side effect no one asked for when the close has nothing to lose.
    /// nil when the user cancelled; otherwise the victims that may now be closed, which is every one
    /// of them unless Save could not reach some.
    /// Asked of the window that owns each tab.
    ///
    /// A tab's live grid and structure edits exist only in its own coordinator: a background
    /// snapshot of a tab in another window reads as clean whatever is staged in it. Once a
    /// connection can be hosted twice, a container's tabs span both windows, and putting all of
    /// them to the coordinator that answered first reported the foreign ones as safe and closed
    /// over the edits without a prompt.
    ///
    /// Cancel anywhere cancels everything, because the entry either closes or it does not.
    private static func confirm(
        _ victims: [QueryTab],
        across coordinators: [MainContentCoordinator],
        revealing workspace: WorkspaceID
    ) async -> Set<UUID>? {
        let everything = Set(victims.map(\.id))
        guard !victims.isEmpty else { return everything }

        var closable: Set<UUID> = []
        /// What each window was showing before it was brought forward to ask. A dirty split
        /// connection reveals more than one of them, and the caller can only put one back, so an
        /// abandoned close left the others switched to a connection the user never chose.
        var revealed: [(host: MainSplitViewController, shown: UUID?)] = []
        func restoreRevealed() {
            for entry in revealed {
                entry.host.workspaces.select(entry.shown)
            }
        }

        for coordinator in coordinators {
            let owned = victims.filter { victim in
                coordinator.tabManager.tabs.contains { $0.id == victim.id }
            }
            guard !owned.isEmpty else { continue }
            guard let actions = coordinator.commandActions else {
                closable.formUnion(owned.map(\.id))
                continue
            }
            guard actions.hasUnsavedWork(among: owned) else {
                closable.formUnion(owned.map(\.id))
                continue
            }
            if let host = coordinator.splitViewController {
                revealed.append((host, host.workspaces.selectedConnectionId))
            }
            reveal(workspace, in: coordinator)
            switch await actions.resolveUnsavedWork(in: owned) {
            case .cancel:
                restoreRevealed()
                return nil
            case .close(let resolved):
                closable.formUnion(resolved)
            }
        }
        /// A victim no window claims is already gone, so nothing is holding work for it.
        let unclaimed = victims.map(\.id).filter { id in
            !coordinators.contains { coordinator in coordinator.tabManager.tabs.contains { $0.id == id } }
        }
        closable.formUnion(unclaimed)
        return closable
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

    /// Brings forward the window that owns the tabs about to be asked about.
    ///
    /// `resolveUnsavedWork` attaches its sheet to its own coordinator's window, so revealing the
    /// connection's first host instead would select one window and then wait on a sheet hanging off
    /// another, behind it or on a different native tab.
    private static func reveal(_ workspace: WorkspaceID, in coordinator: MainContentCoordinator) {
        reveal(workspace, window: coordinator.contentWindow, coordinator: coordinator)
    }

    private static func reveal(_ workspace: WorkspaceID, coordinator: MainContentCoordinator?) {
        reveal(
            workspace,
            window: WindowManager.shared.window(for: workspace.connectionId),
            coordinator: coordinator
        )
    }

    private static func reveal(
        _ workspace: WorkspaceID,
        window: NSWindow?,
        coordinator: MainContentCoordinator?
    ) {
        if let window {
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
