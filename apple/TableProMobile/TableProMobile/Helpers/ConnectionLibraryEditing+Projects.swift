import Foundation
import TableProConnectionLibrary
import TableProModels

nonisolated enum ProjectWriteOutcome: Equatable, Sendable {
    case applied(UUID)
    case unchanged
    case emptyName
    case duplicateName
    case missing
    case refused

    var isSaved: Bool {
        switch self {
        case .applied, .unchanged: true
        default: false
        }
    }
}

nonisolated struct ProjectLibraryChange: Equatable, Sendable {
    let projects: [ConnectionProject]
    let groups: [ConnectionGroup]
    let connections: [DatabaseConnection]
    let changedGroupIds: [UUID]
    let changedConnectionIds: [UUID]
}

nonisolated struct ProjectAssignment: Equatable, Sendable {
    let groups: [ConnectionGroup]
    let connections: [DatabaseConnection]
    let changedGroupIds: [UUID]
    let changedConnectionIds: [UUID]
}

nonisolated extension ConnectionLibraryEditing {
    static func orderedProjects(_ projects: [ConnectionProject]) -> [ConnectionProject] {
        projects.sorted { lhs, rhs in
            lhs.sortOrder == rhs.sortOrder ? lhs.id.uuidString < rhs.id.uuidString : lhs.sortOrder < rhs.sortOrder
        }
    }

    static func projectNameProblem(
        _ name: String,
        in projects: [ConnectionProject],
        excluding excluded: UUID? = nil
    ) -> ProjectWriteOutcome? {
        switch LibraryProjectName.problem(name, among: projects, excluding: excluded) {
        case .empty: .emptyName
        case .duplicate: .duplicateName
        case nil: nil
        }
    }

    static func addingProject(
        named name: String,
        id: UUID = UUID(),
        to projects: [ConnectionProject]
    ) -> (projects: [ConnectionProject], outcome: ProjectWriteOutcome) {
        if let problem = projectNameProblem(name, in: projects) { return (projects, problem) }
        let project = ConnectionProject(
            id: id,
            name: LibraryProjectName.trimmed(name),
            sortOrder: LibraryOrdering.nextSortOrder(after: projects.map(\.sortOrder))
        )
        return (projects + [project], .applied(id))
    }

    static func renamingProject(
        _ id: UUID,
        to name: String,
        in projects: [ConnectionProject]
    ) -> (projects: [ConnectionProject], outcome: ProjectWriteOutcome) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return (projects, .missing) }
        if let problem = projectNameProblem(name, in: projects, excluding: id) { return (projects, problem) }
        let trimmed = LibraryProjectName.trimmed(name)
        guard projects[index].name != trimmed else { return (projects, .unchanged) }
        var result = projects
        result[index].name = trimmed
        return (result, .applied(id))
    }

    static func reorderingProjects(
        _ orderedIds: [UUID],
        in projects: [ConnectionProject]
    ) -> (projects: [ConnectionProject], changed: [UUID]) {
        let ranks = LibraryOrdering.ranks(for: orderedIds)
        var changed: [UUID] = []
        let result = projects.map { project -> ConnectionProject in
            guard let rank = ranks[project.id], rank != project.sortOrder else { return project }
            var updated = project
            updated.sortOrder = rank
            changed.append(project.id)
            return updated
        }
        return (result, changed)
    }

    // The project's groups and connections stay, in no project.
    static func deletingProject(
        _ id: UUID,
        projects: [ConnectionProject],
        groups: [ConnectionGroup],
        connections: [DatabaseConnection]
    ) -> ProjectLibraryChange? {
        guard projects.contains(where: { $0.id == id }) else { return nil }
        let cleared = clearingProjects([id], groups: groups, connections: connections)
        return ProjectLibraryChange(
            projects: projects.filter { $0.id != id },
            groups: cleared.groups,
            connections: cleared.connections,
            changedGroupIds: cleared.changedGroupIds,
            changedConnectionIds: cleared.changedConnectionIds
        )
    }

    static func clearingProjects(
        _ ids: Set<UUID>,
        groups: [ConnectionGroup],
        connections: [DatabaseConnection]
    ) -> ProjectAssignment {
        var changes = LibraryProjectChanges()
        for id in ids {
            let deleted = LibraryProjectNormalizer.deletingProject(id, connections: connections, groups: groups)
            changes.connections.merge(deleted.connections) { _, last in last }
            changes.groups.merge(deleted.groups) { _, last in last }
        }
        return applying(changes, groups: groups, connections: connections)
    }

    // A pull has no order: the update that takes a member out of a group can land before the group's deletion.
    // So membership is read as it stood before the pull. A record whose own project the pull set keeps it.
    static func keepingProjects(
        ofGroupsRemovedFrom before: [ConnectionGroup],
        connectionsBefore: [DatabaseConnection],
        groups: [ConnectionGroup],
        connections: [DatabaseConnection],
        connectionsWithOwnProject: Set<UUID> = [],
        groupsWithOwnProject: Set<UUID> = []
    ) -> ProjectAssignment {
        let removed = Set(before.map(\.id)).subtracting(groups.map(\.id))
        guard !removed.isEmpty else {
            return ProjectAssignment(groups: groups, connections: connections, changedGroupIds: [], changedConnectionIds: [])
        }
        let changes = LibraryPullMembership.keptByReleasedMembers(
            ofGroups: removed,
            connectionsBefore: connectionsBefore,
            groupsBefore: before,
            connections: connections,
            groups: groups,
            connectionsWithOwnProject: connectionsWithOwnProject,
            groupsWithOwnProject: groupsWithOwnProject
        )
        let kept = applying(changes, groups: groups, connections: connections)
        // A dead id would file the entry under the group again if a later pull brought the group back.
        let releasedGroups = kept.groups.map { group -> ConnectionGroup in
            guard let parentId = group.parentId, removed.contains(parentId) else { return group }
            var updated = group
            updated.parentId = nil
            return updated
        }
        let releasedConnections = kept.connections.map { connection -> DatabaseConnection in
            guard let groupId = connection.groupId, removed.contains(groupId) else { return connection }
            var updated = connection
            updated.groupId = nil
            return updated
        }
        return ProjectAssignment(
            groups: releasedGroups,
            connections: releasedConnections,
            changedGroupIds: zip(groups, releasedGroups).filter { $0 != $1 }.map(\.0.id),
            changedConnectionIds: zip(connections, releasedConnections).filter { $0 != $1 }.map(\.0.id)
        )
    }

    // Only what stores a project takes one: a connection in no group and a top-level group. The rest follow their group.
    static func assigningProject(
        _ projectId: UUID?,
        toConnections connectionIds: Set<UUID>,
        groups groupIds: Set<UUID>,
        in connections: [DatabaseConnection],
        groups: [ConnectionGroup]
    ) -> ProjectAssignment {
        let graph = LibraryGroupGraph(groups: groups)
        var changes = LibraryProjectChanges()
        for connection in connections where connectionIds.contains(connection.id) {
            let isGrouped = connection.groupId.map(graph.contains) ?? false
            if !isGrouped, connection.projectId != projectId {
                changes.connections[connection.id] = .some(projectId)
            }
        }
        for group in groups where groupIds.contains(group.id) {
            if graph.parentId(of: group.id) == nil, group.projectId != projectId {
                changes.groups[group.id] = .some(projectId)
            }
        }
        return applying(changes, groups: groups, connections: connections)
    }

    private static func applying(
        _ changes: LibraryProjectChanges,
        groups: [ConnectionGroup],
        connections: [DatabaseConnection]
    ) -> ProjectAssignment {
        ProjectAssignment(
            groups: groups.map { group in
                var updated = group
                updated.projectId = changes.groupProjectId(group.id, current: group.projectId)
                return updated
            },
            connections: connections.map { connection in
                var updated = connection
                updated.projectId = changes.connectionProjectId(connection.id, current: connection.projectId)
                return updated
            },
            changedGroupIds: groups.map(\.id).filter { changes.groups[$0] != nil },
            changedConnectionIds: connections.map(\.id).filter { changes.connections[$0] != nil }
        )
    }
}
