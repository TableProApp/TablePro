//
//  GroupStorage.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProSyncTransport

internal enum GroupStorageError: LocalizedError, Equatable {
    case duplicateName(String)
    case depthExceeded
    case wouldCreateCycle
    case groupNotFound
    case storeUnreadable

    internal var errorDescription: String? {
        switch self {
        case .duplicateName(let name):
            return String(
                format: String(localized: "A group named “%@” already exists here."), name
            )
        case .depthExceeded:
            return String(
                format: String(localized: "Groups nest up to %lld levels."),
                ConnectionGroup.maxNestingDepth
            )
        case .wouldCreateCycle:
            return String(localized: "A group cannot be moved inside itself.")
        case .groupNotFound:
            return String(localized: "That group no longer exists.")
        case .storeUnreadable:
            return String(localized: "The saved groups could not be read. Nothing was changed.")
        }
    }
}

/// Service for persisting connection groups
@MainActor
internal final class GroupStorage {
    internal static let shared = GroupStorage()
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "GroupStorage")

    private let groupsKey = "com.TablePro.groups"
    private let defaults: UserDefaults
    private let syncTracker: SyncChangeTracker
    private let connectionStorageProvider: () -> ConnectionStorage
    private let appEvents: AppEvents
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedGroups: [ConnectionGroup]?
    /// Set when the stored payload could not be understood at all. Every mutation rewrites the
    /// whole array, so continuing over an unreadable store would replace the user's groups with
    /// whatever the caller happened to be holding.
    private var storeIsUnreadable = false

    internal init(
        userDefaults: UserDefaults = .standard,
        syncTracker: SyncChangeTracker = .shared,
        connectionStorage: @escaping @autoclosure () -> ConnectionStorage = .shared,
        appEvents: AppEvents = .shared
    ) {
        self.defaults = userDefaults
        self.syncTracker = syncTracker
        self.connectionStorageProvider = connectionStorage
        self.appEvents = appEvents
    }

    // MARK: - Group CRUD

    /// Load all groups
    ///
    /// A payload that decodes element by element keeps every group it can read: one entry written
    /// by a future version, or truncated on disk, used to take the whole list down with it.
    internal func loadGroups() -> [ConnectionGroup] {
        if let cached = cachedGroups { return cached }

        guard let data = defaults.data(forKey: groupsKey) else {
            storeIsUnreadable = false
            cachedGroups = []
            return []
        }

        if let groups = try? decoder.decode([ConnectionGroup].self, from: data) {
            storeIsUnreadable = false
            cachedGroups = groups
            return groups
        }

        guard let salvaged = try? decoder.decode([SalvagedGroup].self, from: data) else {
            Self.logger.error("Group store could not be read; leaving it untouched")
            storeIsUnreadable = true
            return []
        }

        let groups = salvaged.compactMap(\.group)
        Self.logger.error(
            "Dropped \(salvaged.count - groups.count, privacy: .public) unreadable group entries"
        )
        storeIsUnreadable = false
        cachedGroups = groups
        return groups
    }

    /// Save all groups. Callers that go on to write related state must check the result: a save
    /// that failed leaves the store holding the previous set.
    @discardableResult
    internal func saveGroups(_ groups: [ConnectionGroup]) -> Bool {
        guard !storeIsUnreadable else {
            Self.logger.error("Refusing to overwrite an unreadable group store")
            return false
        }

        do {
            let data = try encoder.encode(groups)
            defaults.set(data, forKey: groupsKey)
            cachedGroups = nil
            syncTracker.markDirty(.group, ids: groups.map { $0.id.uuidString })
            return true
        } catch {
            Self.logger.error("Failed to save groups: \(error)")
            return false
        }
    }

    /// Add a new group (duplicate check scoped to siblings, enforces depth cap and cycle prevention)
    internal func addGroup(_ group: ConnectionGroup) throws {
        var groups = loadGroups()
        try validatePlacement(of: group, in: groups)

        let siblings = groups.filter { $0.parentId == group.parentId }
        guard !siblings.contains(where: { $0.name.lowercased() == group.name.lowercased() }) else {
            throw GroupStorageError.duplicateName(group.name)
        }

        groups.append(group)
        guard saveGroups(groups) else { throw GroupStorageError.storeUnreadable }
        notifyChanged()
    }

    /// Update an existing group (enforces cycle prevention and depth cap on parentId changes)
    internal func updateGroup(_ group: ConnectionGroup) throws {
        var groups = loadGroups()
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else {
            throw GroupStorageError.groupNotFound
        }
        if group.parentId != groups[index].parentId {
            try validatePlacement(of: group, in: groups)
        }

        groups[index] = group
        guard saveGroups(groups) else { throw GroupStorageError.storeUnreadable }
        notifyChanged()
    }

    /// Apply a group that arrived from another device, reporting whether anything changed.
    ///
    /// Written exactly as it arrived. A record cannot be judged on its own, because a pull carries
    /// no dependency order: a hierarchy the other device reversed legally, rooting B and then
    /// moving A under B, arrives as two records, and whichever lands first describes a state that
    /// looks like a cycle against the half of the change that has not arrived yet. Repairing it
    /// here would root A permanently, and the next push would send that back as a revert of a move
    /// the user made. `repairHierarchy` runs once the whole batch is in, when the graph is whole.
    ///
    /// The pull that calls this raises one change notification for the batch, so this raises none.
    ///
    /// A record identical to the one already stored is skipped, because `saveGroups` marks every
    /// group dirty and the push uploads every dirty group. Writing an unchanged record therefore
    /// re-uploads the whole list, which the other device receives and writes back, and two Macs
    /// trade the same records forever. The iOS coordinator has always had this guard.
    @discardableResult
    internal func applyRemoteGroup(_ group: ConnectionGroup) -> Bool {
        var groups = loadGroups()

        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            guard groups[index] != group else { return false }
            groups[index] = group
        } else {
            groups.append(group)
        }

        return saveGroups(groups)
    }

    /// Root every group left on a parent cycle, reporting whether anything moved.
    ///
    /// Called once a pull has applied every record it carried, which is the first moment the graph
    /// can be judged. A cycle that survives to here was authored by a device that should not have
    /// been able to author one, or predates the validation, and leaving it stored would make
    /// `deleteGroup` compute a subtree the list does not show.
    @discardableResult
    internal func repairHierarchy() -> Bool {
        let groups = loadGroups()
        let repaired = groupsWithReachableParents(groups)
        guard repaired != groups else { return false }

        Self.logger.error("Rooting \(cyclicGroupIds(groups).count, privacy: .public) groups left on a parent cycle")
        return saveGroups(repaired)
    }

    /// Delete a group and all descendant groups, nil-out groupId on affected connections
    /// The delete set comes from the graph the list draws, not the raw stored one. A group left on
    /// a cycle is drawn at the top level, and each member of that cycle is a descendant of the
    /// other in the raw graph, so deleting one displayed root used to take the other with it.
    internal func deleteGroup(_ group: ConnectionGroup) {
        var groups = groupsWithReachableParents(loadGroups())
        let descendantIds = collectAllDescendantGroupIds(groupId: group.id, groups: groups)
        let allIdsToDelete = descendantIds.union([group.id])

        groups.removeAll { allIdsToDelete.contains($0.id) }
        guard saveGroups(groups) else { return }

        for deletedId in allIdsToDelete {
            syncTracker.markDeleted(.group, id: deletedId.uuidString)
        }

        let storage = connectionStorageProvider()
        var connections = storage.loadConnections()
        var changed: [DatabaseConnection] = []
        for i in connections.indices {
            if let gid = connections[i].groupId, allIdsToDelete.contains(gid) {
                connections[i].groupId = nil
                changed.append(connections[i])
            }
        }
        if !changed.isEmpty {
            if !storage.updateConnections(changed) {
                Self.logger.error("Failed to clear groupId references after group deletion")
            }
        }
        notifyChanged()
    }

    /// Get group by ID
    internal func group(for id: UUID) -> ConnectionGroup? {
        loadGroups().first { $0.id == id }
    }

    // MARK: - Private

    /// Announced from the mutators rather than from `saveGroups`, because a sync pull applies one
    /// record at a time and raises a single coalesced notification of its own for the batch.
    private func notifyChanged() {
        appEvents.connectionUpdated.send(nil)
    }

    private func validatePlacement(of group: ConnectionGroup, in groups: [ConnectionGroup]) throws {
        guard !wouldCreateCircle(movingGroupId: group.id, toParentId: group.parentId, groups: groups) else {
            throw GroupStorageError.wouldCreateCycle
        }
        guard canPlaceGroup(group.id, under: group.parentId, groups: groups) else {
            throw GroupStorageError.depthExceeded
        }
    }
}

/// Decodes one group and keeps going when it cannot, so a single unreadable entry costs that entry
/// rather than the whole list.
private struct SalvagedGroup: Decodable {
    let group: ConnectionGroup?

    init(from decoder: Decoder) throws {
        group = try? ConnectionGroup(from: decoder)
    }
}
