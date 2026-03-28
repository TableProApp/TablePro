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

    /// Add a new group
    func addGroup(_ group: ConnectionGroup) {
        var groups = loadGroups()
        guard !groups.contains(where: { $0.name.lowercased() == group.name.lowercased() }) else {
            return
        }
        groups.append(group)
        saveGroups(groups)
    }

    /// Update an existing group
    func updateGroup(_ group: ConnectionGroup) {
        var groups = loadGroups()
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
            saveGroups(groups)
        }
    }

    /// Delete a group
    func deleteGroup(_ group: ConnectionGroup) {
        SyncChangeTracker.shared.markDeleted(.group, id: group.id.uuidString)
        var groups = loadGroups()
        groups.removeAll { $0.id == group.id }
        saveGroups(groups)
    }

    /// Get group by ID
    func group(for id: UUID) -> ConnectionGroup? {
        loadGroups().first { $0.id == id }
    }
}
