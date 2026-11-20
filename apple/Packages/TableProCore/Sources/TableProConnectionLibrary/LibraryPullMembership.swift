import Foundation

public enum LibraryPullMembership {
    // A pull has no order: the update that takes a member out of a group can be applied before the group's
    // deletion, so what a deleted group held is read from the library as it stood before the pull. The lists
    // with their own project hold the records whose project the pull itself set, which stay as sent.
    public static func keptByReleasedMembers<Connection: LibraryConnectionRepresentable, Group: LibraryGroupRepresentable>(
        ofGroups deleted: Set<UUID>,
        connectionsBefore: [Connection],
        groupsBefore: [Group],
        connections: [Connection],
        groups: [Group],
        connectionsWithOwnProject: Set<UUID> = [],
        groupsWithOwnProject: Set<UUID> = []
    ) -> LibraryProjectChanges {
        var changes = LibraryProjectChanges()
        guard !deleted.isEmpty else { return changes }
        let before = LibraryProjectScope(groups: groupsBefore, projectIds: [])
        let groupBefore = Dictionary(connectionsBefore.map { ($0.id, $0.groupId) }, uniquingKeysWith: { first, _ in first })
        let remaining = Set(groups.map(\.id)).subtracting(deleted)

        for connection in connections {
            guard let held = groupBefore[connection.id] ?? nil, deleted.contains(held), before.graph.contains(held)
            else { continue }
            // Moved into a group that stays, which decides its project now.
            if let groupId = connection.groupId, remaining.contains(groupId) { continue }
            if connectionsWithOwnProject.contains(connection.id), connection.groupId != held { continue }
            let stored = before.storedProjectId(ofGroupId: held)
            if stored != connection.projectId {
                changes.connections[connection.id] = .some(stored)
            }
        }
        for group in groups where !deleted.contains(group.id) {
            guard let held = before.graph.parentId(of: group.id), deleted.contains(held) else { continue }
            if let parentId = group.parentId, remaining.contains(parentId) { continue }
            if groupsWithOwnProject.contains(group.id), group.parentId != held { continue }
            let stored = before.storedProjectId(ofGroupId: group.id)
            if stored != group.projectId {
                changes.groups[group.id] = .some(stored)
            }
        }
        return changes
    }
}
