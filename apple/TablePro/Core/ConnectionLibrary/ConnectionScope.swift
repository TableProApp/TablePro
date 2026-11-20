//
//  ConnectionScope.swift
//  TablePro
//

import Combine
import Foundation
import TableProConnectionLibrary

// What a scoped surface lists. Two of these differ exactly when such a surface has to reload.
internal struct ConnectionScopeSnapshot: Hashable {
    // Nil is All Connections.
    internal let projectId: UUID?
    internal let connectionIds: Set<UUID>
    internal let groupIds: Set<UUID>
}

// What a listing surface shows. A lookup by id reads `ConnectionStorage`, which is never scoped, so an
// open window of another project keeps its record.
@MainActor
internal final class ConnectionScope {
    internal static let shared = ConnectionScope()
    internal static let activeProjectKey = "com.TablePro.connectionList.activeProjectId"

    private let defaults: UserDefaults
    private let connectionStorageProvider: () -> ConnectionStorage
    private let groupStorageProvider: () -> GroupStorage
    private let projectStorageProvider: () -> ProjectStorage

    // The one scope signal. Sent on the main actor once the scoped connections, the scoped groups or the
    // active project differ from the last ones sent: a switch, a move, a delete, an import, a sync pull.
    // A surface listening to anything else for scope goes stale on one of them.
    internal let scopedSetChanged: AnyPublisher<Void, Never>
    private let scopedSetSubject: PassthroughSubject<Void, Never>
    private var announced: ConnectionScopeSnapshot?
    private var librarySubscription: AnyCancellable?

    internal init(
        userDefaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        connectionStorage: @escaping @autoclosure () -> ConnectionStorage = .shared,
        groupStorage: @escaping @autoclosure () -> GroupStorage = .shared,
        projectStorage: @escaping @autoclosure () -> ProjectStorage = .shared,
        appEvents: AppEvents = .shared
    ) {
        self.defaults = userDefaults
        self.connectionStorageProvider = connectionStorage
        self.groupStorageProvider = groupStorage
        self.projectStorageProvider = projectStorage
        let subject = PassthroughSubject<Void, Never>()
        scopedSetSubject = subject
        scopedSetChanged = subject.eraseToAnyPublisher()
        announced = snapshot
        // Every library write that can move a record in or out of scope ends with this event.
        librarySubscription = appEvents.connectionUpdated
            .sink { [weak self] _ in
                self?.announceIfChanged()
            }
    }

    // MARK: - Active project

    // As chosen on this Mac. It can name a project that is gone, which reads as All Connections.
    internal var storedActiveProjectId: UUID? {
        defaults.string(forKey: Self.activeProjectKey).flatMap(UUID.init(uuidString:))
    }

    // Nil is All Connections.
    internal var activeProjectId: UUID? {
        guard let stored = storedActiveProjectId else { return nil }
        return projectStorageProvider().projectIds.contains(stored) ? stored : nil
    }

    internal var activeProject: ConnectionProject? {
        storedActiveProjectId.flatMap { projectStorageProvider().project(for: $0) }
    }

    internal func setActiveProject(_ projectId: UUID?) {
        guard projectId != storedActiveProjectId else { return }
        if let projectId {
            defaults.set(projectId.uuidString, forKey: Self.activeProjectKey)
        } else {
            defaults.removeObject(forKey: Self.activeProjectKey)
        }
        announceIfChanged()
    }

    // MARK: - Scope signal

    internal var snapshot: ConnectionScopeSnapshot {
        let scoped = current
        return ConnectionScopeSnapshot(
            projectId: scoped.projectId,
            connectionIds: scoped.connectionIds,
            groupIds: Set(scoped.groups.map(\.id))
        )
    }

    private func announceIfChanged() {
        let latest = snapshot
        guard latest != announced else { return }
        announced = latest
        scopedSetSubject.send()
    }

    // MARK: - Scoped library

    // Built from storage on every call, so it never trails an edit, a pull or a switch.
    internal var current: LibraryScopedLibrary<DatabaseConnection, ConnectionGroup> {
        scoped(connections: connectionStorageProvider().loadConnections(), groups: groupStorageProvider().loadGroups())
    }

    // For a caller that already holds the lists it read from storage.
    internal func scoped(
        connections: [DatabaseConnection],
        groups: [ConnectionGroup]
    ) -> LibraryScopedLibrary<DatabaseConnection, ConnectionGroup> {
        LibraryProjectScope(groups: groups, projectIds: projectStorageProvider().projectIds)
            .scoped(connections: connections, groups: groups, active: storedActiveProjectId)
    }

    internal var connections: [DatabaseConnection] {
        current.connections
    }

    internal var groups: [ConnectionGroup] {
        current.groups
    }

    internal var connectionIds: Set<UUID> {
        current.connectionIds
    }

    // Nil in All Connections, where a row whose connection is gone still shows.
    internal var allowedConnectionIds: Set<UUID>? {
        let scoped = current
        return scoped.projectId == nil ? nil : scoped.connectionIds
    }

    internal func contains(connectionId: UUID) -> Bool {
        allowedConnectionIds?.contains(connectionId) ?? true
    }

    // The project a connection is in, through its top-level group when it has one.
    internal func projectId(ofConnection connectionId: UUID) -> UUID? {
        guard let connection = connectionStorageProvider().loadConnection(id: connectionId) else { return nil }
        return LibraryProjectScope(
            groups: groupStorageProvider().loadGroups(),
            projectIds: projectStorageProvider().projectIds
        ).effectiveProjectId(of: connection)
    }

    // MARK: - Form pickers

    // The groups a connection form offers: the active project's, or every group when the connection it
    // edits sits outside the active project. Nil is a new connection.
    internal func groupChoices(forConnection connectionId: UUID?) -> [ConnectionGroup] {
        let groups = groupStorageProvider().loadGroups()
        let scoped = scoped(connections: connectionStorageProvider().loadConnections(), groups: groups)
        guard let connectionId, scoped.projectId != nil, !scoped.connectionIds.contains(connectionId),
              connectionStorageProvider().loadConnection(id: connectionId) != nil else { return scoped.groups }
        return groups
    }

    // The project a group made from a connection form lands in: the active one, or the connection's own
    // when it sits outside the active project.
    internal func placing(_ group: ConnectionGroup, forConnection connectionId: UUID?) -> ConnectionGroup {
        guard let connectionId, let allowed = allowedConnectionIds, !allowed.contains(connectionId),
              connectionStorageProvider().loadConnection(id: connectionId) != nil else {
            return placingInActiveProject(group)
        }
        var placed = group
        placed.projectId = LibraryProjectNormalizer.groupProjectId(
            projectId(ofConnection: connectionId),
            parentId: group.parentId,
            groups: groupStorageProvider().loadGroups()
        )
        return placed
    }

    // MARK: - New records

    // A connection made while a project is active lands in it. Inside a group it stores none, since its
    // top-level group carries the project.
    internal func placingInActiveProject(_ connection: DatabaseConnection) -> DatabaseConnection {
        var placed = connection
        placed.projectId = LibraryProjectNormalizer.connectionProjectId(
            activeProjectId,
            groupId: connection.groupId,
            groups: groupStorageProvider().loadGroups()
        )
        return placed
    }

    // A top-level group made while a project is active lands in it.
    internal func placingInActiveProject(_ group: ConnectionGroup) -> ConnectionGroup {
        var placed = group
        placed.projectId = LibraryProjectNormalizer.groupProjectId(
            activeProjectId,
            parentId: group.parentId,
            groups: groupStorageProvider().loadGroups()
        )
        return placed
    }
}
