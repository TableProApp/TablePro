//
//  GroupStorage.swift
//  TablePro
//

import Foundation
import os

/// Service for persisting connection groups
final class GroupStorage {
    static let shared = GroupStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "GroupStorage")

    private let groupsKey = "com.TablePro.groups"
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedGroups: [ConnectionGroup]?

    private init() {}

    // MARK: - Group CRUD

    /// Load all groups
    func loadGroups() -> [ConnectionGroup] {
        if let cached = cachedGroups { return cached }

        guard let data = defaults.data(forKey: groupsKey) else {
            cachedGroups = []
            return []
        }

        do {
            let groups = try decoder.decode([ConnectionGroup].self, from: data)
            cachedGroups = groups
            return groups
        } catch {
            Self.logger.error("Failed to load groups: \(error)")
            cachedGroups = []
            return []
        }
    }

    /// Save all groups
    func saveGroups(_ groups: [ConnectionGroup]) {
        do {
            let data = try encoder.encode(groups)
            defaults.set(data, forKey: groupsKey)
            cachedGroups = nil
            SyncChangeTracker.shared.markDirty(.group, ids: groups.map { $0.id.uuidString })
        } catch {
            Self.logger.error("Failed to save groups: \(error)")
        }
    }

    /// Add a new group (duplicate check scoped to siblings, enforces depth cap and cycle prevention)
    func addGroup(_ group: ConnectionGroup) {
        var groups = loadGroups()
        guard !wouldCreateCircle(movingGroupId: group.id, toParentId: group.parentId, groups: groups) else { return }
        guard validateDepth(parentId: group.parentId) else { return }
        let siblings = groups.filter { $0.parentId == group.parentId }
        guard !siblings.contains(where: { $0.name.lowercased() == group.name.lowercased() }) else {
            return
        }
        groups.append(group)
        saveGroups(groups)
    }

    /// Update an existing group (enforces cycle prevention and depth cap on parentId changes)
    func updateGroup(_ group: ConnectionGroup) {
        var groups = loadGroups()
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        if group.parentId != groups[index].parentId {
            guard !wouldCreateCircle(movingGroupId: group.id, toParentId: group.parentId, groups: groups) else { return }
            guard validateDepth(parentId: group.parentId) else { return }
        }
        groups[index] = group
        saveGroups(groups)
    }

    /// Delete a group and all descendant groups, nil-out groupId on affected connections
    func deleteGroup(_ group: ConnectionGroup) {
        var groups = loadGroups()
        let descendantIds = collectAllDescendantGroupIds(groupId: group.id, groups: groups)
        let allIdsToDelete = descendantIds.union([group.id])

        for deletedId in allIdsToDelete {
            SyncChangeTracker.shared.markDeleted(.group, id: deletedId.uuidString)
        }

        groups.removeAll { allIdsToDelete.contains($0.id) }
        saveGroups(groups)

        let storage = ConnectionStorage.shared
        var connections = storage.loadConnections()
        var changed = false
        for i in connections.indices {
            if let gid = connections[i].groupId, allIdsToDelete.contains(gid) {
                connections[i].groupId = nil
                changed = true
            }
        }
        if changed {
            storage.saveConnections(connections)
        }
    }

    /// Get group by ID
    func group(for id: UUID) -> ConnectionGroup? {
        loadGroups().first { $0.id == id }
    }

    /// Validate that adding a child under parentId would not exceed max depth
    func validateDepth(parentId: UUID?, maxDepth: Int = 3) -> Bool {
        guard let pid = parentId else { return true }
        let groups = loadGroups()
        let parentDepth = depthOf(groupId: pid, groups: groups)
        return parentDepth < maxDepth
    }
}
