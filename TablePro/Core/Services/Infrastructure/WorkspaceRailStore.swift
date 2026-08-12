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
    internal static var entries: [WorkspaceRailEntry] {
        let openIds = WindowLifecycleMonitor.shared.allConnectionIds()
            .union(WindowManager.shared.allConnectionIds())
        guard !openIds.isEmpty else { return [] }

        let sessions = DatabaseManager.shared.activeSessions
        let sessionless = openIds.filter { sessions[$0] == nil }
        return resolveEntries(
            openConnectionIds: openIds,
            sessions: sessions,
            storedConnections: Self.storedConnections(for: Array(sessionless)),
            containerTarget: { PluginManager.shared.containerSwitchTarget(for: $0) },
            tabs: { MainContentCoordinator.allTabs(for: $0) },
            browsedContainers: { Self.browsedContainers(for: $0) },
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
        browsedContainers: (UUID) -> Set<String>,
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

            let browsed = browsedContainers(connectionId)
            for container in containers(
                for: resolved,
                tabs: tabs(connectionId),
                browsed: browsed,
                target: target
            ) {
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

    /// The workspace one window is showing right now.
    ///
    /// Scoped to a window, not a connection: a connection reaches many containers and can have
    /// a window open on several of them at once, so asking "which workspace is this connection
    /// showing" has no single answer. Answering it from the shared session made every window's
    /// rail highlight whichever container another window had most recently switched to. (#2088)
    internal static func browsedWorkspace(ofWindow coordinator: MainContentCoordinator) -> WorkspaceID {
        let target = PluginManager.shared.containerSwitchTarget(for: coordinator.connection.type)
        let container = WorkspaceAnchoring.named(
            database: coordinator.browseDatabaseName,
            schema: coordinator.browseSchemaName,
            target: target
        ) ?? ""
        return WorkspaceID(connectionId: coordinator.connectionId, container: container)
    }

    /// Every container the connection's open windows are browsing. The rail lists a row per
    /// container, and a window that has browsed somewhere with no tabs open yet still earns one.
    internal static func browsedContainers(for connectionId: UUID) -> Set<String> {
        Set(
            MainContentCoordinator.allActiveCoordinators()
                .filter { $0.connectionId == connectionId }
                .compactMap { coordinator in
                    WorkspaceAnchoring.named(
                        database: coordinator.browseDatabaseName,
                        schema: coordinator.browseSchemaName,
                        target: PluginManager.shared.containerSwitchTarget(for: coordinator.connection.type)
                    )
                }
        )
    }

    /// The row the rail keeps selected. A window whose session has gone still belongs to
    /// its connection, so it falls back to that connection's first row rather than showing
    /// nothing selected until it reconnects.
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

    /// A rail always shows its own window's workspace. Dispatching to another connection hands
    /// the user to a different window, so the rail that sent them there returns its selection to
    /// where it belongs instead of standing on a row that describes somebody else.
    ///
    /// Nothing else restores it. `connectionWindowsChanged` reports a window becoming key only
    /// the first time, so once every window has been focused once a rail left pointing at a
    /// foreign row would stay there: the row it now needs to act on is the one it already thinks
    /// is selected, and selecting it again is not a change, so the next click would do nothing.
    internal static func shouldRestoreSelection(after target: WorkspaceID, railConnectionId: UUID?) -> Bool {
        guard let railConnectionId else { return false }
        return target.connectionId != railConnectionId
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
        browsed: Set<String>,
        target: ContainerSwitchTarget?
    ) -> Set<String> {
        var containers = WorkspaceAnchoring.containers(in: tabs, target: target)
        containers.formUnion(browsed)

        /// Only when no window has a cursor yet, which is a connection whose window exists but
        /// has no coordinator registered. A window that is browsing always speaks for itself.
        if browsed.isEmpty,
           let fallback = WorkspaceAnchoring.defaultContainer(of: resolved.connection, target: target) {
            containers.insert(fallback)
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
