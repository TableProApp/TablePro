//
//  WorkspaceRailStore.swift
//  TablePro
//

import Combine
import Foundation

internal struct WorkspaceRailEntry: Identifiable, Equatable {
    internal let workspace: WorkspaceID
    internal let connection: DatabaseConnection
    internal let status: ConnectionStatus
    /// What the container names on this engine, so the row can say "schema public" rather
    /// than calling every container a database.
    internal let containerTarget: ContainerSwitchTarget?

    internal init(
        workspace: WorkspaceID,
        connection: DatabaseConnection,
        status: ConnectionStatus,
        containerTarget: ContainerSwitchTarget? = .database
    ) {
        self.workspace = workspace
        self.connection = connection
        self.status = status
        self.containerTarget = containerTarget
    }

    internal var id: WorkspaceID { workspace }
    internal var container: String { workspace.container }
}

@MainActor
internal enum WorkspaceRailStore {
    /// Derived live from the open windows, their sessions and their tabs rather than
    /// cached, so a refresh can never blank the list it is refreshing.
    /// Membership comes from the windows' own workspace registries and nothing else. A connection is
    /// in the rail exactly while some window hosts it, which is what a rail row means.
    ///
    /// `WindowLifecycleMonitor` used to be unioned in here. It tracks mounted content rather than
    /// hosted connections, and the two stopped agreeing in both directions: it kept naming a
    /// connection whose workspace had been closed, which is the row that would not go away, and it
    /// answered nothing for connections that were open. It never held an id `WindowManager` lacked,
    /// so the union only ever added wrong answers.
    internal static var entries: [WorkspaceRailEntry] {
        let hosted = WindowManager.shared.hostedWorkspaces()
        let openIds = Set(hosted.map(\.connectionId))
        guard !openIds.isEmpty else { return [] }

        let sessions = DatabaseManager.shared.activeSessions
        let sessionless = openIds.filter { sessions[$0] == nil }
        let workspacesById = hosted.reduce(into: [UUID: ConnectionWorkspace]()) { result, workspace in
            result[workspace.connectionId] = workspace
        }
        return resolveEntries(
            openConnectionIds: openIds,
            sessions: sessions,
            hostedConnections: workspacesById.compactMapValues(\.connection),
            storedConnections: Self.storedConnections(for: Array(sessionless)),
            containerTarget: { PluginManager.shared.containerSwitchTarget(for: $0) },
            /// The hosted workspace's own coordinator, never the app-wide registry: that one also
            /// lists the throwaway coordinators SwiftUI discards mid-body, whose stale copy of a
            /// closed tab kept a container listed and made a closed entry come back.
            tabs: { workspacesById[$0]?.sessionState?.coordinator.tabManager.tabs ?? [] },
            openedContainers: { workspacesById[$0]?.openedContainers ?? [] },
            closingContainers: { workspacesById[$0]?.closingContainer },
            openedAt: workspacesById.mapValues(\.openedAt),
            storedOrder: WorkspaceRailOrderStore.shared.order
        )
    }

    /// A connection contributes one row per container it has open: the ones it was told to open,
    /// the ones its tabs hold, and the one it is browsing. A window can outlive its session: it
    /// exists before the connection is established, and it stays open after a session is torn down.
    /// Such an entry falls back to the record its own workspace carries, and to the saved connection
    /// after that, and reports `.disconnected`, which is what "no session" means, rather than
    /// claiming a connection attempt that may not be running.
    internal static func resolveEntries(
        openConnectionIds: Set<UUID>,
        sessions: [UUID: ConnectionSession],
        hostedConnections: [UUID: DatabaseConnection] = [:],
        storedConnections: [UUID: DatabaseConnection],
        containerTarget: (DatabaseType) -> ContainerSwitchTarget?,
        tabs: (UUID) -> [QueryTab],
        openedContainers: (UUID) -> Set<String> = { _ in [] },
        closingContainers: (UUID) -> String? = { _ in nil },
        openedAt: [UUID: Date] = [:],
        storedOrder: [WorkspaceID]
    ) -> [WorkspaceRailEntry] {
        var connections: [UUID: DatabaseConnection] = [:]
        var statuses: [UUID: ConnectionStatus] = [:]
        var targets: [UUID: ContainerSwitchTarget] = [:]
        var workspaces: Set<WorkspaceID> = []

        for connectionId in openConnectionIds {
            guard let resolved = resolve(
                connectionId: connectionId,
                sessions: sessions,
                hostedConnections: hostedConnections,
                storedConnections: storedConnections
            ) else { continue }

            connections[connectionId] = resolved.connection
            statuses[connectionId] = resolved.status

            let target = containerTarget(resolved.connection.type)
            targets[connectionId] = target

            let held = containers(
                for: resolved,
                tabs: tabs(connectionId),
                opened: openedContainers(connectionId),
                closing: closingContainers(connectionId),
                target: target
            )
            for container in held {
                workspaces.insert(WorkspaceID(connectionId: connectionId, container: container))
            }
        }

        let ranked = WorkspaceRailOrdering.ranked(
            openIds: workspaces,
            storedOrder: storedOrder,
            openedAt: openedAt
        )

        return ranked.compactMap { workspace in
            guard let connection = connections[workspace.connectionId],
                  let status = statuses[workspace.connectionId] else { return nil }
            return WorkspaceRailEntry(
                workspace: workspace,
                connection: connection,
                status: status,
                containerTarget: targets[workspace.connectionId]
            )
        }
    }

    /// The workspace a connection's window is showing right now, or nil while it has no
    /// session to browse with.
    internal static func browsedWorkspace(for connectionId: UUID) -> WorkspaceID? {
        guard let session = DatabaseManager.shared.session(for: connectionId) else { return nil }
        let target = PluginManager.shared.containerSwitchTarget(for: session.connection.type)
        let container = WorkspaceAnchoring.browsedContainer(of: session, target: target) ?? ""
        return WorkspaceID(connectionId: connectionId, container: container)
    }

    /// The row the rail keeps selected, given the connection its window is currently showing.
    /// A connection whose session has gone is still the one the window is on, so it falls back to
    /// that connection's first row rather than showing nothing selected until it reconnects.
    internal static func selectedRow(
        connectionId: UUID?,
        browsed: WorkspaceID?,
        in workspaces: [WorkspaceID]
    ) -> Int? {
        guard let connectionId else { return nil }
        if let browsed, let row = workspaces.firstIndex(of: browsed) {
            return row
        }
        return workspaces.firstIndex { $0.connectionId == connectionId }
    }

    internal static var changes: AnyPublisher<Void, Never> {
        let events = AppEvents.shared
        return Publishers.MergeMany(
            events.connectionWindowsChanged.eraseToAnyPublisher(),
            events.workspaceRailOrderChanged.eraseToAnyPublisher(),
            events.workspaceTabsChanged.eraseToAnyPublisher(),
            events.browseContainerChanged.map { _ in () }.eraseToAnyPublisher(),
            events.connectionStatusChanged.map { _ in () }.eraseToAnyPublisher(),
            events.connectionUpdated.map { _ in () }.eraseToAnyPublisher()
        )
        .eraseToAnyPublisher()
    }

    internal static func applyVisibleOrder(_ ids: [WorkspaceID]) {
        WorkspaceRailOrderStore.shared.applyVisibleOrder(ids)
    }

    private struct ResolvedConnection {
        let connection: DatabaseConnection
        let status: ConnectionStatus
        let session: ConnectionSession?
    }

    /// The window's own record comes before the saved one, and is the only one a connection opened
    /// from a file or a URL ever has: `TabRouter.openDatabaseFile` builds that connection inline and
    /// never writes it to `ConnectionStorage`. Resolving from storage alone dropped every one of its
    /// entries the moment its session ended, while its window was still open and hosting it.
    private static func resolve(
        connectionId: UUID,
        sessions: [UUID: ConnectionSession],
        hostedConnections: [UUID: DatabaseConnection],
        storedConnections: [UUID: DatabaseConnection]
    ) -> ResolvedConnection? {
        if let session = sessions[connectionId] {
            return ResolvedConnection(
                connection: session.connection,
                status: session.reportedStatus,
                session: session
            )
        }
        guard let record = hostedConnections[connectionId] ?? storedConnections[connectionId] else { return nil }
        return ResolvedConnection(connection: record, status: .disconnected, session: nil)
    }

    /// An engine that switches neither database nor schema names no container, and a
    /// connection that has not reached one yet names nothing either. Both still get one
    /// row, keyed by the empty container, so every open window is reachable from the rail.
    ///
    /// `opened` is what the user has open and has not closed. Tabs are still read alongside it,
    /// because a restored window has tabs before anything has browsed anywhere.
    ///
    /// The live browse cursor always earns a row: it is where the next tab opens, and a container
    /// the connection is standing in cannot be closed without leaving it first. The saved default is
    /// a last resort instead, for a window whose session has gone or has not arrived: taking it
    /// unconditionally put the connection's own database back the moment its entry was closed, on
    /// exactly the connection that has no session to browse away with.
    private static func containers(
        for resolved: ResolvedConnection,
        tabs: [QueryTab],
        opened: Set<String>,
        closing: String?,
        target: ContainerSwitchTarget?
    ) -> Set<String> {
        var containers = WorkspaceAnchoring.containers(in: tabs, target: target)
        containers.formUnion(opened)

        if let browsed = resolved.session.flatMap({
            WorkspaceAnchoring.browsedContainer(of: $0, target: target)
        }) {
            /// Except while a close is leaving it. The connection is still standing there until the
            /// switch lands, which on an engine that reconnects to change database is seconds away,
            /// and keeping the row until then left a closed entry on screen long after the click.
            /// It comes back if the switch fails, because the connection never left after all.
            if browsed != closing || containers.isEmpty {
                containers.insert(browsed)
            }
        } else if containers.isEmpty,
                  let saved = WorkspaceAnchoring.defaultContainer(of: resolved.connection, target: target) {
            containers.insert(saved)
        }
        if containers.isEmpty {
            containers.insert("")
        }
        return containers
    }

    private static func storedConnections(for ids: [UUID]) -> [UUID: DatabaseConnection] {
        guard !ids.isEmpty else { return [:] }
        let wanted = Set(ids)
        return ConnectionStorage.shared.loadConnections()
            .filter { wanted.contains($0.id) }
            .reduce(into: [:]) { result, connection in
                result[connection.id] = connection
            }
    }
}
