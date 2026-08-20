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
        let openIds = WindowManager.shared.allConnectionIds()
        guard !openIds.isEmpty else { return [] }

        let sessions = DatabaseManager.shared.activeSessions
        let sessionless = openIds.filter { sessions[$0] == nil }
        return resolveEntries(
            openConnectionIds: openIds,
            sessions: sessions,
            storedConnections: Self.storedConnections(for: Array(sessionless)),
            containerTarget: { PluginManager.shared.containerSwitchTarget(for: $0) },
            tabs: { MainContentCoordinator.allTabs(for: $0) },
            storedOrder: WorkspaceRailOrderStore.shared.order
        )
    }

    /// A connection contributes one row per container its tabs hold open, plus the one it
    /// is browsing. A window can outlive its session: it exists before the connection is
    /// established, and it stays open after a session is torn down. Such an entry falls
    /// back to the saved connection record and reports `.disconnected`, which is what "no
    /// session" means, rather than claiming a connection attempt that may not be running.
    internal static func resolveEntries(
        openConnectionIds: Set<UUID>,
        sessions: [UUID: ConnectionSession],
        storedConnections: [UUID: DatabaseConnection],
        containerTarget: (DatabaseType) -> ContainerSwitchTarget?,
        tabs: (UUID) -> [QueryTab],
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
                storedConnections: storedConnections
            ) else { continue }

            connections[connectionId] = resolved.connection
            statuses[connectionId] = resolved.status

            let target = containerTarget(resolved.connection.type)
            targets[connectionId] = target

            for container in containers(for: resolved, tabs: tabs(connectionId), target: target) {
                workspaces.insert(WorkspaceID(connectionId: connectionId, container: container))
            }
        }

        let ranked = WorkspaceRailOrdering.ranked(
            openIds: workspaces,
            storedOrder: storedOrder,
            openedAt: sessions.mapValues(\.connectedAt)
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

    private static func resolve(
        connectionId: UUID,
        sessions: [UUID: ConnectionSession],
        storedConnections: [UUID: DatabaseConnection]
    ) -> ResolvedConnection? {
        if let session = sessions[connectionId] {
            return ResolvedConnection(connection: session.connection, status: session.status, session: session)
        }
        guard let stored = storedConnections[connectionId] else { return nil }
        return ResolvedConnection(connection: stored, status: .disconnected, session: nil)
    }

    /// An engine that switches neither database nor schema names no container, and a
    /// connection that has not reached one yet names nothing either. Both still get one
    /// row, keyed by the empty container, so every open window is reachable from the rail.
    private static func containers(
        for resolved: ResolvedConnection,
        tabs: [QueryTab],
        target: ContainerSwitchTarget?
    ) -> Set<String> {
        var containers = WorkspaceAnchoring.containers(in: tabs, target: target)

        let browsed = resolved.session.flatMap {
            WorkspaceAnchoring.browsedContainer(of: $0, target: target)
        } ?? WorkspaceAnchoring.defaultContainer(of: resolved.connection, target: target)

        if let browsed {
            containers.insert(browsed)
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
