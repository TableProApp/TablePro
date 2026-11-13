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

    /// The entry Close takes in a window that shows an entry with no tab left: that container, or
    /// nil when it is the connection's only entry, which closing would take the connection with.
    internal static func closableEntry(connectionId: UUID, container: String?) -> WorkspaceRailEntry? {
        guard let container, !container.isEmpty else { return nil }
        let entries = WorkspaceRailStore.entries.filter { $0.workspace.connectionId == connectionId }
        guard scope(entryCount: entries.count) == .container else { return nil }
        return entries.first { $0.container == container }
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
            close container=\(workspace.container, privacy: .private(mask: .hash)) \
            listed=[\(containers.joined(separator: " "), privacy: .private(mask: .hash))] \
            scope=\(String(describing: scope(entryCount: containers.count)), privacy: .private)
            """
        )
        guard scope(entryCount: containers.count) == .container, !workspace.container.isEmpty else {
            await ConnectionCloseAction.close(connectionId: workspace.connectionId)
            return
        }
        // Every window hosting the connection: a torn-off tab can be the container's only one.
        let hostedWorkspaces = WindowManager.shared.workspaces(for: workspace.connectionId)
        guard let hosted = hostedWorkspaces.first else {
            Self.logger.error("close has no hosted workspace container=\(workspace.container, privacy: .private(mask: .hash))")
            return
        }

        let coordinators = hostedWorkspaces.compactMap { $0.sessionState?.coordinator }
        let coordinator = coordinators.first
        // Asking reveals the work at risk, so an answer that closes nothing puts the window back here.
        let wasShowing = WindowManager.shared.shownConnection(besides: workspace.connectionId)
        // Running work, then unsaved work, then the transaction, read after the save: Save under Manual Commit lands in one.
        let victims = committedTabs(in: workspace.container, across: coordinators)
        // Closing a tab stops its query, so a yes needs no cancel of its own.
        let running = RunningWorkRegistry.shared.items(in: .tabs(Set(victims.map(\.id))))
        let holdsUnsavedWork = coordinators.contains { coordinator in
            coordinator.commandActions?.hasUnsavedWork(among: victims.filter { victim in
                coordinator.tabManager.tabs.contains { $0.id == victim.id }
            }) == true
        }
        if !holdsUnsavedWork, let prompt = RunningWorkPrompt.make(action: .close, work: running) {
            // Shown, then asked: the first host can be minimized or a background tab.
            let owner = coordinators.first { coordinator in
                running.contains { work in work.tabId.map { id in coordinator.tabManager.tabs.contains { $0.id == id } } ?? false }
            } ?? coordinator
            if let owner { reveal(workspace, in: owner) }
            guard await RunningWorkApproval.confirm(prompt, window: owner?.contentWindow) else {
                WindowManager.shared.show(wasShowing, inWindowHosting: workspace.connectionId)
                return
            }
        }
        guard let confirmed = await confirm(
            victims, across: coordinators, revealing: workspace, alsoStopping: holdsUnsavedWork ? running : []
        ) else {
            WindowManager.shared.show(wasShowing, inWindowHosting: workspace.connectionId)
            Self.logger.info("close cancelled at the save prompt container=\(workspace.container, privacy: .private(mask: .hash))")
            return
        }
        let closable = confirmed.closable
        // A tab whose work the save could not take keeps the container open: the alert promised it would stay.
        guard closable.isSuperset(of: Set(victims.map(\.id))) else {
            closeTabs(victims.map(\.id).filter { closable.contains($0) }, across: coordinators)
            WindowManager.shared.show(wasShowing, inWindowHosting: workspace.connectionId)
            Self.logger.info(
                """
                close kept container=\(workspace.container, privacy: .private(mask: .hash)) \
                unsaveable=\(victims.count - closable.count, privacy: .public)
                """
            )
            return
        }
        // Before anything closes, so a Cancel or a failed commit leaves the entry as it was.
        guard await resolveTransaction(in: workspace) else {
            confirmed.restoreRevealed()
            WindowManager.shared.show(wasShowing, inWindowHosting: workspace.connectionId)
            Self.logger.info("close cancelled at the transaction prompt container=\(workspace.container, privacy: .private(mask: .hash))")
            return
        }
        // One session serves every entry, so its transaction outlives the close, and an engine that cannot switch
        // database inside one refuses the move: moving first means a refusal closes nothing.
        let movesFirst = await holdsSessionWideTransaction(workspace.connectionId)
        if movesFirst {
            guard await browseAway(from: workspace, among: containers, coordinator: coordinator) else {
                confirmed.restoreRevealed()
                WindowManager.shared.show(wasShowing, inWindowHosting: workspace.connectionId)
                Self.logger.error(
                    "close could not leave container=\(workspace.container, privacy: .private(mask: .hash))"
                )
                return
            }
        }
        // Otherwise the entry goes before the connection leaves the container: leaving can be a reconnect, and
        // waiting for it left the closed row on the strip for seconds. `beginClosing` lets the strip drop the
        // browse cursor's own row early, and the cursor follows underneath.
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
            close done container=\(workspace.container, privacy: .private(mask: .hash)) \
            tabsClosed=\(victims.count, privacy: .public) \
            opened=[\(hosted.openedContainers.sorted().joined(separator: " "), privacy: .private(mask: .hash))]
            """
        )

        var left = true
        if !movesFirst {
            left = await browseAway(from: workspace, among: containers, coordinator: coordinator)
        }
        if left {
            leave(workspace, in: coordinators)
        }
        for hostedWorkspace in hostedWorkspaces {
            hostedWorkspace.endClosing()
        }
        guard left else {
            // The connection never left, so the next tab still opens there; the driver's error is already on screen.
            for hostedWorkspace in hostedWorkspaces {
                hostedWorkspace.openContainer(workspace.container)
            }
            WindowManager.shared.show(wasShowing, inWindowHosting: workspace.connectionId)
            Self.logger.error(
                "close could not leave container=\(workspace.container, privacy: .private(mask: .hash))"
            )
            return
        }

        // Read again: a table opened while the switch ran anchors the container anew, and has nothing to lose.
        let opened = coordinators.flatMap { tabs(in: workspace.container, of: $0) }
        if !opened.isEmpty {
            closeTabs(opened.map(\.id), across: coordinators)
            for hostedWorkspace in hostedWorkspaces {
                hostedWorkspace.closeContainer(workspace.container)
            }
        }
        // Closing the entry ends the database's own connection and catalog; the browse cursor moved off it above.
        DatabaseManager.shared.sessionLanes.close(database: workspace.container, for: workspace.connectionId)
        SchemaService.shared.forget(database: workspace.container, connectionId: workspace.connectionId)
    }

    // nil when the user cancelled; otherwise the victims that may close (all, unless Save could not reach some) and
    // the windows revealed to ask, for a later Cancel to put back. Each tab is asked of the window that owns it,
    // since its live edits exist only in its own coordinator, and only when it holds unsaved work: revealing a
    // background window is a side effect no one asked for when nothing is lost. Cancel anywhere cancels everything.
    private static func confirm(
        _ victims: [QueryTab],
        across coordinators: [MainContentCoordinator],
        revealing workspace: WorkspaceID,
        alsoStopping running: [RunningWork]
    ) async -> Confirmation? {
        var running = running
        let everything = Set(victims.map(\.id))
        guard !victims.isEmpty else { return Confirmation(closable: everything, revealed: []) }

        var closable: Set<UUID> = []
        // A dirty split connection reveals more than one window, and the caller can only put one back.
        var revealed: [RevealedWindow] = []
        func restoreRevealed() {
            for window in revealed {
                window.restore()
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
            revealed.append(RevealedWindow(coordinator: coordinator))
            reveal(workspace, in: coordinator)
            // The first save question names the running work; the next ones need not repeat it.
            let named = running
            running = []
            switch await actions.resolveUnsavedWork(in: owned, alsoStopping: named) {
            case .cancel:
                restoreRevealed()
                return nil
            case .close(let resolved):
                closable.formUnion(resolved)
            }
        }
        // A victim no window claims is already gone, so nothing is holding work for it.
        let unclaimed = victims.map(\.id).filter { id in
            !coordinators.contains { coordinator in coordinator.tabManager.tabs.contains { $0.id == id } }
        }
        closable.formUnion(unclaimed)
        return Confirmation(closable: closable, revealed: revealed)
    }

    @MainActor
    private struct Confirmation {
        let closable: Set<UUID>
        let revealed: [RevealedWindow]

        func restoreRevealed() {
            for window in revealed {
                window.restore()
            }
        }
    }

    /// A window as it was before it was brought forward to ask: the connection it showed, and that
    /// connection's entry and tab.
    @MainActor
    private struct RevealedWindow {
        let coordinator: MainContentCoordinator
        let host: MainSplitViewController?
        let shownConnection: UUID?
        let entry: String?
        let tab: UUID?

        init(coordinator: MainContentCoordinator) {
            self.coordinator = coordinator
            self.host = coordinator.splitViewController
            self.shownConnection = host?.workspaces.selectedConnectionId
            self.entry = coordinator.tabManager.visibleContainer
            self.tab = coordinator.tabManager.selectedTabId
        }

        func restore() {
            host?.workspaces.select(shownConnection)
            let manager = coordinator.tabManager
            manager.show(container: entry)
            guard let tab, manager.tabs.contains(where: { $0.id == tab }) else { return }
            manager.selectedTabId = tab
        }
    }

    // Only a database with its own connection loses a transaction when its entry closes. Nothing is revealed: the
    // alert names the database, and the transaction is in no one tab.
    private static func resolveTransaction(in workspace: WorkspaceID) async -> Bool {
        let manager = DatabaseManager.shared
        guard let session = manager.session(for: workspace.connectionId),
              manager.usesDatabaseLanes(session)
        else { return true }
        let outcome = await TransactionEndingFlow.resolve(
            connectionId: workspace.connectionId,
            action: .closeEntry(database: workspace.container),
            among: [workspace.container],
            window: { WindowManager.shared.window(for: workspace.connectionId) }
        )
        return outcome != .cancelled
    }

    private static func holdsSessionWideTransaction(_ connectionId: UUID) async -> Bool {
        let manager = DatabaseManager.shared
        guard let session = manager.session(for: connectionId), !manager.usesDatabaseLanes(session) else { return false }
        let holding = await manager.databasesHoldingTransaction(for: connectionId)
        return !holding.isEmpty
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

    /// Every window still showing the closed entry goes to the one the connection browses. The
    /// window whose cursor moved away is there already; a window a tab was torn off into, or one
    /// that only showed the entry to ask about its unsaved work, is not, and would otherwise be left
    /// on an entry the strip no longer lists.
    private static func leave(_ workspace: WorkspaceID, in coordinators: [MainContentCoordinator]) {
        for coordinator in coordinators where coordinator.tabManager.visibleContainer == workspace.container {
            coordinator.browseCursorCoordinator.showBrowsedContainer()
        }
    }

    private static func listedContainers(of connectionId: UUID) -> [String] {
        WorkspaceRailStore.entries
            .filter { $0.workspace.connectionId == connectionId }
            .map(\.container)
    }

    // An open cell editor or the editor's pending text in a window's selected tab is unsaved work too, so it lands
    // before the tabs are read.
    internal static func committedTabs(in container: String, across coordinators: [MainContentCoordinator]) -> [QueryTab] {
        for coordinator in coordinators {
            let selected = coordinator.tabManager.selectedTabId
            guard tabs(in: container, of: coordinator).contains(where: { $0.id == selected }) else { continue }
            coordinator.commitActiveGridEdit()
        }
        return coordinators.flatMap { tabs(in: container, of: $0) }
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
        /// Shown to be asked about, not gone to: the object browser stays where it is, and a
        /// Cancel puts the entry back the way it was.
        coordinator?.tabManager.show(container: workspace.container)
    }
}
