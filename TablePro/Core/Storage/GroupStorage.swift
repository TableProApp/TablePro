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
    private let expandedGroupsKey = "com.TablePro.expandedGroups"
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    // MARK: - Group CRUD

    /// Load all groups
    func loadGroups() -> [ConnectionGroup] {
        guard let data = defaults.data(forKey: groupsKey) else {
            return []
        }

        do {
            var groups = try decoder.decode([ConnectionGroup].self, from: data)
            migrateSortOrderIfNeeded(&groups)
            return groups
        } catch {
            Self.logger.error("Failed to load groups: \(error)")
            return []
        }
    }

    /// Assign sequential sortOrder when all items have default 0 (legacy migration).
    private func migrateSortOrderIfNeeded(_ groups: inout [ConnectionGroup]) {
        guard groups.count > 1, groups.allSatisfy({ $0.sortOrder == 0 }) else { return }
        for index in groups.indices {
            groups[index].sortOrder = index
        }
        saveGroups(groups)
        let count = groups.count
        Self.logger.info("Migrated sortOrder for \(count) groups")
    }

    /// Save all groups
    func saveGroups(_ groups: [ConnectionGroup]) {
        do {
            let data = try encoder.encode(groups)
            defaults.set(data, forKey: groupsKey)
            SyncChangeTracker.shared.markDirty(.group, ids: groups.map { $0.id.uuidString })
        } catch {
            Self.logger.error("Failed to save groups: \(error)")
        }
    }

    /// Add a new group (rejects case-insensitive duplicate names among siblings).
    /// Returns `true` if the group was added, `false` if a sibling with the same name exists.
    @discardableResult
    func addGroup(_ group: ConnectionGroup) -> Bool {
        var groups = loadGroups()
        let hasDuplicate = groups.contains {
            $0.parentGroupId == group.parentGroupId
                && $0.name.caseInsensitiveCompare(group.name) == .orderedSame
        }
        if hasDuplicate {
            Self.logger.debug("Ignoring attempt to add duplicate group name: \(group.name, privacy: .public)")
            return false
        }
        groups.append(group)
        saveGroups(groups)
        return true
    }

    /// Update an existing group
    func updateGroup(_ group: ConnectionGroup) {
        var groups = loadGroups()
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
            saveGroups(groups)
        }
    }

    /// Delete a group and all its descendants, including their connections.
    func deleteGroup(_ group: ConnectionGroup) {
        SyncChangeTracker.shared.markDeleted(.group, id: group.id.uuidString)
        var groups = loadGroups()
        let deletedIds = collectDescendantIds(of: group.id, in: groups)
        let allDeletedIds = deletedIds.union([group.id])

        // Remove deleted groups
        groups.removeAll { allDeletedIds.contains($0.id) }
        saveGroups(groups)

        // Delete connections that belonged to deleted groups
        let storage = ConnectionStorage.shared
        let connections = storage.loadConnections()
        var remaining: [DatabaseConnection] = []
        for conn in connections {
            if let gid = conn.groupId, allDeletedIds.contains(gid) {
                // Clean up keychain entries
                storage.deletePassword(for: conn.id)
                storage.deleteSSHPassword(for: conn.id)
                storage.deleteKeyPassphrase(for: conn.id)
            } else {
                remaining.append(conn)
            }
        }
        storage.saveConnections(remaining)
    }

    /// Count all connections inside a group and its descendants.
    func connectionCount(for group: ConnectionGroup) -> Int {
        let allGroups = loadGroups()
        let descendantIds = collectDescendantIds(of: group.id, in: allGroups)
        let allGroupIds = descendantIds.union([group.id])
        let connections = ConnectionStorage.shared.loadConnections()
        return connections.filter { conn in
            guard let gid = conn.groupId else { return false }
            return allGroupIds.contains(gid)
        }.count
    }

    /// Get group by ID
    func group(for id: UUID) -> ConnectionGroup? {
        loadGroups().first { $0.id == id }
    }

    /// Get child groups of a parent, sorted by sortOrder
    func childGroups(of parentId: UUID?) -> [ConnectionGroup] {
        loadGroups()
            .filter { $0.parentGroupId == parentId }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Get the next sort order for a new item in a parent context
    func nextSortOrder(parentId: UUID?) -> Int {
        let siblings = loadGroups().filter { $0.parentGroupId == parentId }
        return (siblings.map(\.sortOrder).max() ?? -1) + 1
    }

    // MARK: - Expanded State

    /// Load the set of expanded group IDs
    func loadExpandedGroupIds() -> Set<UUID> {
        guard let data = defaults.data(forKey: expandedGroupsKey) else {
            return []
        }

        do {
            let ids = try decoder.decode([UUID].self, from: data)
            return Set(ids)
        } catch {
            Self.logger.error("Failed to load expanded groups: \(error)")
            return []
        }
    }

    /// Save the set of expanded group IDs
    func saveExpandedGroupIds(_ ids: Set<UUID>) {
        do {
            let data = try encoder.encode(Array(ids))
            defaults.set(data, forKey: expandedGroupsKey)
        } catch {
            Self.logger.error("Failed to save expanded groups: \(error)")
        }
    }

    // MARK: - Helpers

    /// Recursively collect all descendant group IDs
    func collectDescendantIds(of groupId: UUID, in groups: [ConnectionGroup]) -> Set<UUID> {
        var result = Set<UUID>()
        let children = groups.filter { $0.parentGroupId == groupId }
        for child in children {
            result.insert(child.id)
            result.formUnion(collectDescendantIds(of: child.id, in: groups))
        }
        return result
    }
}
