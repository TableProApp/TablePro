import Foundation

public struct LibraryScopedLibrary<Connection: LibraryConnectionRepresentable, Group: LibraryGroupRepresentable> {
    // Nil is All Connections.
    public let projectId: UUID?
    public let connections: [Connection]
    public let groups: [Group]
    public let connectionIds: Set<UUID>

    public init(projectId: UUID?, connections: [Connection], groups: [Group]) {
        self.projectId = projectId
        self.connections = connections
        self.groups = groups
        connectionIds = Set(connections.map(\.id))
    }
}

public struct LibraryProjectScope: Sendable {
    public let projectIds: Set<UUID>
    public let graph: LibraryGroupGraph
    private let storedByGroup: [UUID: UUID]

    public init<Group: LibraryGroupRepresentable, Project: LibraryProjectRepresentable>(
        groups: [Group],
        projects: [Project]
    ) {
        self.init(groups: groups, projectIds: Set(projects.map(\.id)))
    }

    public init<Group: LibraryGroupRepresentable>(groups: [Group], projectIds: Set<UUID>) {
        self.projectIds = projectIds
        graph = LibraryGroupGraph(groups: groups)
        var stored: [UUID: UUID] = [:]
        for group in groups where stored[group.id] == nil {
            stored[group.id] = group.projectId
        }
        storedByGroup = stored
    }

    // Nil for All Connections, and for an id no project holds.
    public func resolved(_ projectId: UUID?) -> UUID? {
        projectId.flatMap { projectIds.contains($0) ? $0 : nil }
    }

    public func rootGroupId(of groupId: UUID) -> UUID? {
        graph.pathIds(to: groupId).first
    }

    public func effectiveProjectId(ofGroupId groupId: UUID) -> UUID? {
        resolved(storedProjectId(ofGroupId: groupId))
    }

    public func effectiveProjectId<Group: LibraryGroupRepresentable>(of group: Group) -> UUID? {
        graph.contains(group.id) ? effectiveProjectId(ofGroupId: group.id) : resolved(group.projectId)
    }

    public func effectiveProjectId<Connection: LibraryConnectionRepresentable>(of connection: Connection) -> UUID? {
        resolved(storedProjectId(of: connection))
    }

    // What the root group stores, kept as written even when no project holds it.
    public func storedProjectId(ofGroupId groupId: UUID) -> UUID? {
        rootGroupId(of: groupId).flatMap { storedByGroup[$0] }
    }

    public func storedProjectId<Connection: LibraryConnectionRepresentable>(of connection: Connection) -> UUID? {
        if let groupId = connection.groupId, graph.contains(groupId) {
            return storedProjectId(ofGroupId: groupId)
        }
        return connection.projectId
    }

    public func scoped<Connection: LibraryConnectionRepresentable, Group: LibraryGroupRepresentable>(
        connections: [Connection],
        groups: [Group],
        active: UUID?
    ) -> LibraryScopedLibrary<Connection, Group> {
        guard let projectId = resolved(active) else {
            return LibraryScopedLibrary(projectId: nil, connections: connections, groups: groups)
        }
        return LibraryScopedLibrary(
            projectId: projectId,
            connections: connections.filter { effectiveProjectId(of: $0) == projectId },
            groups: groups.filter { effectiveProjectId(of: $0) == projectId }
        )
    }

    public static func scoped<
        Connection: LibraryConnectionRepresentable,
        Group: LibraryGroupRepresentable,
        Project: LibraryProjectRepresentable
    >(
        connections: [Connection],
        groups: [Group],
        projects: [Project],
        active: UUID?
    ) -> LibraryScopedLibrary<Connection, Group> {
        LibraryProjectScope(groups: groups, projects: projects)
            .scoped(connections: connections, groups: groups, active: active)
    }

    // Root groups are siblings only inside one project, so two projects can each hold a "Production".
    public func siblingGroupId<Group: LibraryGroupRepresentable>(
        named name: String,
        parentId: UUID?,
        projectId: UUID?,
        in groups: [Group],
        excluding excluded: Set<UUID> = []
    ) -> UUID? {
        let key = LibraryProjectName.folded(name)
        let project = resolved(projectId)
        return groups.first { group in
            guard !excluded.contains(group.id),
                  graph.parentId(of: group.id) == parentId,
                  LibraryProjectName.folded(group.name) == key
            else { return false }
            return parentId != nil || effectiveProjectId(ofGroupId: group.id) == project
        }?.id
    }
}
