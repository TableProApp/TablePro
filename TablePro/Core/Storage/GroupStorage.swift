//
//  GroupStorage.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProConnectionLibrary
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
        userDefaults: UserDefaults = AppStorageEnvironment.shared.defaults,
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

    /// Add a new group at the end of its parent (duplicate check scoped to siblings, enforces depth
    /// cap and cycle prevention)
    internal func addGroup(_ group: ConnectionGroup) throws {
        var groups = loadGroups()
        try validatePlacement(of: group, in: groups)
        try validateUniqueName(group.name, parentId: group.parentId, excluding: [group.id], in: groups)

        var placed = group
        placed.sortOrder = LibraryOrdering.nextSortOrder(
            after: groups.filter { $0.parentId == group.parentId }.map(\.sortOrder)
        )
        groups.append(placed)
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

    internal func mutateGroup(id: UUID, _ mutate: (inout ConnectionGroup) -> Void) throws {
        var groups = loadGroups()
        guard let index = groups.firstIndex(where: { $0.id == id }) else {
            throw GroupStorageError.groupNotFound
        }
        let original = groups[index]
        var updated = original
        mutate(&updated)
        guard updated != original else { return }

        if updated.parentId != original.parentId {
            try validatePlacement(of: updated, in: groups)
        }
        let nameChanged = updated.name.lowercased() != original.name.lowercased()
        if nameChanged || updated.parentId != original.parentId {
            try validateUniqueName(updated.name, parentId: updated.parentId, excluding: [id], in: groups)
        }

        groups[index] = updated
        guard saveGroups(groups) else { throw GroupStorageError.storeUnreadable }
        notifyChanged()
    }

    internal func moveGroups(_ ids: [UUID], toParent parentId: UUID?, before: UUID?) throws {
        var groups = loadGroups()
        let existing = Set(groups.map(\.id))
        var seen: Set<UUID> = []
        let moving = ids.filter { existing.contains($0) && seen.insert($0).inserted }
        guard !moving.isEmpty else { throw GroupStorageError.groupNotFound }

        let graph = LibraryGroupGraph(groups: groups)
        for id in moving {
            if let problem = graph.placementProblem(id, under: parentId) {
                throw Self.error(for: problem)
            }
        }

        let movingSet = Set(moving)
        for id in moving {
            guard let name = groups.first(where: { $0.id == id })?.name else { continue }
            let clashes = groups.contains { other in
                !movingSet.contains(other.id)
                    && graph.parentId(of: other.id) == parentId
                    && other.name.lowercased() == name.lowercased()
            }
            if clashes { throw GroupStorageError.duplicateName(name) }
        }

        let siblingIds = graph.sortedChildIds(of: parentId, mode: .manual).filter { !movingSet.contains($0) }
        let ranks: [UUID: Int]
        if let before, siblingIds.contains(before) {
            ranks = LibraryOrdering.ranks(for: LibraryOrdering.reordered(siblingIds, moving: moving, before: before))
        } else {
            let siblingSet = Set(siblingIds)
            let start = LibraryOrdering.nextSortOrder(
                after: groups.filter { siblingSet.contains($0.id) }.map(\.sortOrder)
            )
            ranks = Dictionary(uniqueKeysWithValues: moving.enumerated().map { ($0.element, start + $0.offset) })
        }

        for index in groups.indices {
            if movingSet.contains(groups[index].id) {
                groups[index].parentId = parentId
            }
            if let rank = ranks[groups[index].id] {
                groups[index].sortOrder = rank
            }
        }
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
    internal func applyRemoteGroup(_ group: ConnectionGroup) -> RemoteApplyOutcome {
        var groups = loadGroups()

        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            guard groups[index] != group else { return .skipped }
            groups[index] = group
        } else {
            groups.append(group)
        }

        return saveGroups(groups) ? .applied : .failed
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
        let cyclic = LibraryGroupGraph.cyclicGroupIds(in: groups)
        guard !cyclic.isEmpty else { return false }

        Self.logger.error("Rooting \(cyclic.count, privacy: .public) groups left on a parent cycle")
        let repaired = groups.map { group -> ConnectionGroup in
            guard cyclic.contains(group.id) else { return group }
            var rooted = group
            rooted.parentId = nil
            return rooted
        }
        return saveGroups(repaired)
    }

    /// Delete a group and all descendant groups, nil-out groupId on affected connections.
    @discardableResult
    internal func deleteGroup(_ group: ConnectionGroup) -> Bool {
        var groups = loadGroups()
        let graph = LibraryGroupGraph(groups: groups)
        let allIdsToDelete = graph.descendantIds(of: group.id).union([group.id])

        groups.removeAll { allIdsToDelete.contains($0.id) }
        guard saveGroups(groups) else { return false }

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
        return true
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
        guard let problem = LibraryGroupGraph(groups: groups).placementProblem(group.id, under: group.parentId) else {
            return
        }
        throw Self.error(for: problem)
    }

    private func validateUniqueName(
        _ name: String,
        parentId: UUID?,
        excluding ids: Set<UUID>,
        in groups: [ConnectionGroup]
    ) throws {
        let clashes = groups.contains { other in
            !ids.contains(other.id) && other.parentId == parentId && other.name.lowercased() == name.lowercased()
        }
        guard !clashes else { throw GroupStorageError.duplicateName(name) }
    }

    private static func error(for problem: LibraryGroupGraph.PlacementProblem) -> GroupStorageError {
        switch problem {
        case .cycle:
            return .wouldCreateCycle
        case .depthExceeded:
            return .depthExceeded
        case .missingParent:
            return .groupNotFound
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
