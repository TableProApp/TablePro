import Foundation

// The stored `projectId` each record takes. A record that is not listed keeps what it stores.
public struct LibraryProjectChanges: Equatable, Sendable {
    public var connections: [UUID: UUID?] = [:]
    public var groups: [UUID: UUID?] = [:]

    public init() {}

    public var isEmpty: Bool {
        connections.isEmpty && groups.isEmpty
    }

    public func connectionProjectId(_ id: UUID, current: UUID?) -> UUID? {
        connections[id] ?? current
    }

    public func groupProjectId(_ id: UUID, current: UUID?) -> UUID? {
        groups[id] ?? current
    }
}

// For local edits only. A pulled record is stored as it arrived, since a pull carries no order.
public enum LibraryProjectNormalizer {
    // Every function reads the library as it is before the move or the delete.
    public static func movingConnections<Connection: LibraryConnectionRepresentable, Group: LibraryGroupRepresentable>(
        _ ids: [UUID],
        toGroup groupId: UUID?,
        connections: [Connection],
        groups: [Group]
    ) -> LibraryProjectChanges {
        let scope = LibraryProjectScope(groups: groups, projectIds: [])
        let moving = Set(ids)
        let entersGroup = groupId.map(scope.graph.contains) ?? false
        var changes = LibraryProjectChanges()
        for connection in connections where moving.contains(connection.id) {
            let stored = entersGroup ? nil : scope.storedProjectId(of: connection)
            if stored != connection.projectId {
                changes.connections[connection.id] = .some(stored)
            }
        }
        return changes
    }

    public static func movingGroups<Group: LibraryGroupRepresentable>(
        _ ids: [UUID],
        toParent parentId: UUID?,
        groups: [Group]
    ) -> LibraryProjectChanges {
        let scope = LibraryProjectScope(groups: groups, projectIds: [])
        let moving = Set(ids)
        let entersGroup = parentId.map(scope.graph.contains) ?? false
        var changes = LibraryProjectChanges()
        for group in groups where moving.contains(group.id) {
            let stored = entersGroup ? nil : scope.storedProjectId(ofGroupId: group.id)
            if stored != group.projectId {
                changes.groups[group.id] = .some(stored)
            }
        }
        return changes
    }

    // Pass every group that goes, the subtree included. What they held moves to the root and stays in the project.
    public static func deletingGroups<Connection: LibraryConnectionRepresentable, Group: LibraryGroupRepresentable>(
        _ ids: Set<UUID>,
        connections: [Connection],
        groups: [Group]
    ) -> LibraryProjectChanges {
        let scope = LibraryProjectScope(groups: groups, projectIds: [])
        var changes = LibraryProjectChanges()
        for connection in connections {
            guard let groupId = connection.groupId, ids.contains(groupId), scope.graph.contains(groupId) else { continue }
            let stored = scope.storedProjectId(ofGroupId: groupId)
            if stored != connection.projectId {
                changes.connections[connection.id] = .some(stored)
            }
        }
        for group in groups where !ids.contains(group.id) {
            guard let parentId = scope.graph.parentId(of: group.id), ids.contains(parentId) else { continue }
            let stored = scope.storedProjectId(ofGroupId: group.id)
            if stored != group.projectId {
                changes.groups[group.id] = .some(stored)
            }
        }
        return changes
    }

    public static func deletingProject<Connection: LibraryConnectionRepresentable, Group: LibraryGroupRepresentable>(
        _ projectId: UUID,
        connections: [Connection],
        groups: [Group]
    ) -> LibraryProjectChanges {
        var changes = LibraryProjectChanges()
        for connection in connections where connection.projectId == projectId {
            changes.connections[connection.id] = .some(nil)
        }
        for group in groups where group.projectId == projectId {
            changes.groups[group.id] = .some(nil)
        }
        return changes
    }

    // For a form save: a connection in a group stores no project of its own.
    public static func connectionProjectId<Group: LibraryGroupRepresentable>(
        _ projectId: UUID?,
        groupId: UUID?,
        groups: [Group]
    ) -> UUID? {
        guard let groupId, groups.contains(where: { $0.id == groupId }) else { return projectId }
        return nil
    }

    // For a form save: only a top-level group stores a project.
    public static func groupProjectId<Group: LibraryGroupRepresentable>(
        _ projectId: UUID?,
        parentId: UUID?,
        groups: [Group]
    ) -> UUID? {
        guard let parentId, groups.contains(where: { $0.id == parentId }) else { return projectId }
        return nil
    }
}
