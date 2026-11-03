//
//  WorkspaceRailStore.swift
//  TablePro
//

import Combine
import Foundation
import TableProConnectionLibrary

internal struct WorkspaceRailEntry: Identifiable, Equatable {
    internal let workspace: WorkspaceID
    internal let connection: DatabaseConnection
    internal let status: ConnectionDisplayStatus
    /// What the container names on this engine, so the row can say "schema public" rather
    /// than calling every container a database.
    internal let containerTarget: ContainerSwitchTarget?
    /// A session connection behind this entry holds a transaction, so it shows from other entries.
    internal let transaction: SessionTransactionTracker.State?
    // A session entry exists, so Disconnect has something to end.
    internal let holdsSession: Bool

    internal init(
        workspace: WorkspaceID,
        connection: DatabaseConnection,
        status: ConnectionDisplayStatus,
        containerTarget: ContainerSwitchTarget? = .database,
        transaction: SessionTransactionTracker.State? = nil,
        holdsSession: Bool = true
    ) {
        self.workspace = workspace
        self.connection = connection
        self.status = status
        self.containerTarget = containerTarget
        self.transaction = transaction
        self.holdsSession = holdsSession
    }

    internal var id: WorkspaceID { workspace }
    internal var container: String { workspace.container }
    internal var holdsTransaction: Bool { transaction != nil }
    internal var presentation: ConnectionStatusPresentation { ConnectionStatusPresentation(status) }
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

        let manager = DatabaseManager.shared
        let sessions = manager.activeSessions
        let sessionless = openIds.filter { sessions[$0] == nil }
        /// Every window hosting a connection, not one of them: a tab torn off into its own window
        /// still holds its container, and keeping one workspace per connection dropped the other
        /// window's entries depending on dictionary order.
        let workspacesById = Dictionary(grouping: hosted, by: \.connectionId)
        let coordinatorsById = workspacesById.mapValues { $0.compactMap { $0.sessionState?.coordinator } }
        return resolveEntries(
            openConnectionIds: openIds,
            sessions: sessions,
            phases: workspacesById.mapValues { $0.map(\.phase) },
            endReasons: openIds.reduce(into: [:]) { reasons, id in reasons[id] = manager.disconnectReason(for: id) },
            hostedConnections: workspacesById.compactMapValues { $0.lazy.compactMap(\.connection).first },
            storedConnections: Self.storedConnections(for: Array(sessionless)),
            containerTarget: { PluginManager.shared.containerSwitchTarget(for: $0) },
            /// The hosted workspaces' own coordinators, never the app-wide registry: that one also
            /// lists the throwaway coordinators SwiftUI discards mid-body, whose stale copy of a
            /// closed tab kept a container listed and made a closed entry come back.
            tabs: { coordinatorsById[$0]?.flatMap(\.tabManager.tabs) ?? [] },
            openedContainers: { workspacesById[$0]?.reduce(into: Set<String>()) { $0.formUnion($1.openedContainers) } ?? [] },
            closingContainers: { workspacesById[$0]?.lazy.compactMap(\.closingContainer).first },
            visibleContainers: { Set(coordinatorsById[$0]?.compactMap(\.tabManager.visibleContainer) ?? []) },
            openedAt: workspacesById.compactMapValues { $0.map(\.openedAt).min() },
            storedOrder: WorkspaceRailOrderStore.shared.order,
            transaction: { workspace in
                manager.sessionTransactions.transactionState(
                    connectionId: workspace.connectionId,
                    container: workspace.container
                )
            }
        )
    }

    /// A connection contributes one row per container it has open: the ones it was told to open,
    /// the ones its tabs hold, and the one it is browsing. A window can outlive its session: it
    /// exists before the connection is established, and it stays open after a session is torn down.
    /// Such an entry falls back to the record its own workspace carries, and to the saved connection
    /// after that. Its status comes from the hosting workspaces' phases, which tell a failed connect
    /// from a lost session from one never dialed.
    internal static func resolveEntries(
        openConnectionIds: Set<UUID>,
        sessions: [UUID: ConnectionSession],
        phases: [UUID: [ConnectionWindowPhase]] = [:],
        endReasons: [UUID: ConnectionEndReason] = [:],
        hostedConnections: [UUID: DatabaseConnection] = [:],
        storedConnections: [UUID: DatabaseConnection],
        containerTarget: (DatabaseType) -> ContainerSwitchTarget?,
        tabs: (UUID) -> [QueryTab],
        openedContainers: (UUID) -> Set<String> = { _ in [] },
        closingContainers: (UUID) -> String? = { _ in nil },
        visibleContainers: (UUID) -> Set<String> = { _ in [] },
        openedAt: [UUID: Date] = [:],
        storedOrder: [WorkspaceID],
        transaction: (WorkspaceID) -> SessionTransactionTracker.State? = { _ in nil }
    ) -> [WorkspaceRailEntry] {
        var connections: [UUID: DatabaseConnection] = [:]
        var statuses: [UUID: ConnectionDisplayStatus] = [:]
        var sessionIds: Set<UUID> = []
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
            if resolved.session != nil { sessionIds.insert(connectionId) }
            statuses[connectionId] = ConnectionStatusResolver.status(
                phases: phases[connectionId] ?? [],
                session: resolved.session,
                endReason: endReasons[connectionId]
            )

            let target = containerTarget(resolved.connection.type)
            targets[connectionId] = target

            let closing = closingContainers(connectionId)
            let shown = visibleContainers(connectionId).filter { $0 != closing }
            let held = containers(
                for: resolved,
                tabs: tabs(connectionId),
                opened: openedContainers(connectionId).union(shown),
                closing: closing,
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
                containerTarget: targets[workspace.connectionId],
                transaction: transaction(workspace),
                holdsSession: sessionIds.contains(workspace.connectionId)
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
            events.visibleContainerChanged.eraseToAnyPublisher(),
            events.browseContainerChanged.map { _ in () }.eraseToAnyPublisher(),
            events.connectionStatusChanged.map { _ in () }.eraseToAnyPublisher(),
            events.connectionUpdated.map { _ in () }.eraseToAnyPublisher(),
            events.sessionTransactionsChanged.map { _ in () }.eraseToAnyPublisher()
        )
        .eraseToAnyPublisher()
    }

    // Separate from `changes`: a phase moves a status, never membership, so it repaints rows without a reload.
    internal static var statusChanges: AnyPublisher<UUID, Never> {
        AppEvents.shared.connectionPhaseChanged.eraseToAnyPublisher()
    }

    internal static func applyVisibleOrder(_ ids: [WorkspaceID]) {
        WorkspaceRailOrderStore.shared.applyVisibleOrder(ids)
    }

    private struct ResolvedConnection {
        let connection: DatabaseConnection
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
            return ResolvedConnection(connection: session.connection, session: session)
        }
        guard let record = hostedConnections[connectionId] ?? storedConnections[connectionId] else { return nil }
        return ResolvedConnection(connection: record, session: nil)
    }

    /// An engine that switches neither database nor schema names no container, and a
    /// connection that has not reached one yet names nothing either. Both still get one
    /// row, keyed by the empty container, so every open window is reachable from the rail.
    ///
    /// `opened` is what the user has open and has not closed, plus the entry each window shows.
    /// Every container a tab names is listed too, because a tab is only reachable through its entry.
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
