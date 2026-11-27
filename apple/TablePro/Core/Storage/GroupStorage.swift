//
//  GroupStorage.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProConnectionLibrary
import TableProImport
import TableProSyncTransport

internal enum GroupStorageError: LocalizedError, Equatable {
    case duplicateName(String)
    case depthExceeded
    case wouldCreateCycle
    case groupNotFound
    case storeUnreadable
    case membersNotSaved

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
        case .membersNotSaved:
            return String(localized: "The connections in this group could not be saved. Nothing was changed.")
        }
    }
}

internal struct ConnectionGroupPlacement: Equatable {
    internal let parentId: UUID?
    internal let projectId: UUID?
    internal let sortOrder: Int
}

@MainActor
internal final class GroupStorage {
    internal static let shared = GroupStorage()
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "GroupStorage")

    private let groupsKey = "com.TablePro.groups"
    private let defaults: UserDefaults
    private let syncTracker: SyncChangeTracker
    private let connectionStorageProvider: () -> ConnectionStorage
    private let appEvents: AppEvents
    private let projectIdsProvider: () -> Set<UUID>
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedGroups: [ConnectionGroup]?
    // Records this build cannot read. Every write puts them back as they were read.
    private var preserved: [UnreadableLibraryRecord] = []
    // Every write replaces the whole list, so a payload that could not be read is never written over.
    internal private(set) var storeIsUnreadable = false

    internal init(
        userDefaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        syncTracker: SyncChangeTracker = .shared,
        connectionStorage: @escaping @autoclosure () -> ConnectionStorage = .shared,
        appEvents: AppEvents = .shared,
        projectIds: (() -> Set<UUID>)? = nil
    ) {
        // The projects live in the same suite, so the ids that resolve are read from it.
        self.projectIdsProvider = projectIds ?? { ProjectStorage.projectIds(in: userDefaults) }
        self.defaults = userDefaults
        self.syncTracker = syncTracker
        self.connectionStorageProvider = connectionStorage
        self.appEvents = appEvents
    }

    // MARK: - Group CRUD

    // An entry that does not decode is kept as it was read, and the rest of the list loads.
    internal func loadGroups() -> [ConnectionGroup] {
        if let cached = cachedGroups { return cached }

        guard let data = defaults.data(forKey: groupsKey) else {
            storeIsUnreadable = false
            preserved = []
            cachedGroups = []
            return []
        }

        guard let records = try? LibraryFileRecords<ConnectionGroup>(decoding: data, using: decoder) else {
            Self.logger.error("Group store could not be read; leaving it untouched")
            storeIsUnreadable = true
            preserved = []
            return []
        }

        if !records.unreadable.isEmpty {
            Self.logger.error("Kept \(records.unreadable.count, privacy: .public) group entries this build cannot read")
        }
        storeIsUnreadable = false
        preserved = records.unreadable
        cachedGroups = records.elements
        return records.elements
    }

    // Loads first, so the answer does not depend on whether anything has read the store yet. A connection or a
    // group that names one of these ids keeps naming it, and lists as ungrouped until a build reads the group.
    internal var unreadableGroupIds: Set<UUID> {
        _ = loadGroups()
        return Set(preserved.compactMap(\.id))
    }

    // False leaves the store holding the previous set. A save carrying the id of a record this build cannot read
    // is refused. `removingUnreadable` drops such records by id, as a deletion another device made does.
    @discardableResult
    internal func saveGroups(
        _ groups: [ConnectionGroup],
        removingUnreadable removedIds: Set<UUID> = []
    ) -> Bool {
        let previous = loadGroups()
        guard !storeIsUnreadable else {
            Self.logger.error("Refusing to overwrite an unreadable group store")
            return false
        }

        do {
            let encoded = try LibraryFileRecords.encoded(
                groups, keeping: preserved, removing: removedIds, using: encoder
            )
            defaults.set(encoded.data, forKey: groupsKey)
            preserved = encoded.kept
            cachedGroups = nil
            syncTracker.markDirty(.group, ids: SyncRecordChanges.changedIds(from: previous, to: groups))
            return true
        } catch {
            Self.logger.error("Failed to save groups: \(error.publicLogShape, privacy: .public)")
            return false
        }
    }

    internal func addGroup(_ group: ConnectionGroup) throws {
        var groups = loadGroups()
        try validatePlacement(of: group, in: groups)
        var placed = group
        placed.projectId = LibraryProjectNormalizer.groupProjectId(group.projectId, parentId: group.parentId, groups: groups)
        try validateUniqueName(placed, excluding: [group.id], in: groups)

        placed.iconName = LibrarySymbolCatalog.normalizedName(group.iconName)
        placed.sortOrder = LibraryOrdering.nextSortOrder(
            after: groups.filter { $0.parentId == group.parentId }.map(\.sortOrder)
        )
        groups.append(placed)
        guard saveGroups(groups) else { throw GroupStorageError.storeUnreadable }
        notifyChanged()
    }

    internal func updateGroup(_ group: ConnectionGroup) throws {
        var groups = loadGroups()
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else {
            throw GroupStorageError.groupNotFound
        }
        if group.parentId != groups[index].parentId {
            try validatePlacement(of: group, in: groups)
        }

        var updated = group
        updated.projectId = LibraryProjectNormalizer.groupProjectId(group.projectId, parentId: group.parentId, groups: groups)
        groups[index] = updated
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
            // Read before the move: a group that leaves its parent keeps the project it was in.
            updated.projectId = LibraryProjectNormalizer
                .movingGroups([id], toParent: updated.parentId, groups: groups)
                .groupProjectId(id, current: original.projectId)
        } else {
            updated.projectId = LibraryProjectNormalizer.groupProjectId(
                updated.projectId, parentId: updated.parentId, groups: groups
            )
        }
        guard updated != original else { return }
        let nameChanged = !LibraryProjectName.same(updated.name, original.name)
        if nameChanged || updated.parentId != original.parentId || updated.projectId != original.projectId {
            try validateUniqueName(updated, excluding: [id], in: groups)
        }

        groups[index] = updated
        guard saveGroups(groups) else { throw GroupStorageError.storeUnreadable }
        notifyChanged()
    }

    /// The edit sheet's save, as one write: a rename and a move saved separately could keep the
    /// rename and then refuse the move. A new parent takes the group at its end, as a move does.
    /// Writes only the fields `edited` changed from `opening`, onto the group as it is stored now,
    /// so a rename or a move synced in while the sheet was open survives a save that changed only
    /// the icon.
    internal func editGroup(id: UUID, from opening: ConnectionGroupFields, to edited: ConnectionGroupFields) throws {
        let groups = loadGroups()
        guard let current = groups.first(where: { $0.id == id }) else {
            throw GroupStorageError.groupNotFound
        }
        let movesParent = edited.parentId != opening.parentId && edited.parentId != current.parentId
        let sortOrder = movesParent
            ? LibraryOrdering.nextSortOrder(
                after: groups.filter { $0.parentId == edited.parentId && $0.id != id }.map(\.sortOrder)
            )
            : current.sortOrder
        try mutateGroup(id: id) { group in
            if edited.name != opening.name { group.name = edited.name }
            if edited.color != opening.color { group.color = edited.color }
            if edited.iconName != opening.iconName {
                group.iconName = LibrarySymbolCatalog.normalizedName(edited.iconName)
            }
            if edited.parentId != opening.parentId {
                group.parentId = edited.parentId
                group.sortOrder = sortOrder
            }
        }
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
        // Read before the move: a group that leaves its parent keeps the project it was in.
        let projects = LibraryProjectNormalizer.movingGroups(moving, toParent: parentId, groups: groups)
        try validateNames(
            ofArriving: moving.filter { graph.parentId(of: $0) != parentId },
            parentId: parentId,
            scope: projectScope(of: groups),
            in: groups
        ) { projects.groupProjectId($0.id, current: $0.projectId) }

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
                groups[index].projectId = projects.groupProjectId(groups[index].id, current: groups[index].projectId)
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
    /// A record identical to the one already stored is skipped. The iOS coordinator has always had
    /// this guard.
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
        let projects = LibraryProjectNormalizer.movingGroups(Array(cyclic), toParent: nil, groups: groups)
        let repaired = groups.map { group -> ConnectionGroup in
            guard cyclic.contains(group.id) else { return group }
            var rooted = group
            rooted.parentId = nil
            rooted.projectId = projects.groupProjectId(group.id, current: group.projectId)
            return rooted
        }
        return saveGroups(repaired)
    }

    // The members are saved before the group goes, and the tombstones follow the last write, so a sync
    // they start reads the finished state. False when either write failed.
    @discardableResult
    internal func deleteGroup(_ group: ConnectionGroup) -> Bool {
        let groups = loadGroups()
        guard !storeIsUnreadable else { return false }
        let deletedIds = LibraryGroupGraph(groups: groups).descendantIds(of: group.id).union([group.id])

        guard let remaining = removingGroups(deletedIds, from: groups, byUser: true) else { return false }
        guard saveGroups(remaining) else { return false }
        for deletedId in deletedIds {
            syncTracker.markDeleted(.group, id: deletedId.uuidString)
        }
        notifyChanged()
        return true
    }

    // A deletion another device made: no tombstone and no notification, which the pull raises once.
    @discardableResult
    internal func applyRemoteDeletions(_ ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return true }
        let groups = loadGroups()
        guard !storeIsUnreadable else { return false }
        guard let remaining = removingGroups(ids, from: groups, byUser: false) else { return false }
        // A group always syncs, so one this build cannot read goes by its id.
        return saveGroups(remaining, removingUnreadable: ids)
    }

    // Clears the members first, a Local only connection too, so no connection is left naming a group that is gone.
    // What the groups held moves to the top level and stays in their project.
    private func removingGroups(
        _ ids: Set<UUID>,
        from groups: [ConnectionGroup],
        byUser: Bool
    ) -> [ConnectionGroup]? {
        let storage = connectionStorageProvider()
        let connections = storage.loadConnections()
        // A library that cannot be read cannot be cleared, so the group stays for its members.
        guard !storage.lastLoadFailed else { return nil }
        let projects = LibraryProjectNormalizer.deletingGroups(ids, connections: connections, groups: groups)
        let cleared = storage.rewriteMembership(byUser: byUser) { connection in
            guard let groupId = connection.groupId, ids.contains(groupId) else { return }
            connection.groupId = nil
            connection.projectId = projects.connectionProjectId(connection.id, current: connection.projectId)
        }
        guard cleared else {
            Self.logger.error("Kept a group: its connections could not be saved without it")
            return nil
        }
        return groups
            .filter { !ids.contains($0.id) }
            .map { group in
                var kept = group
                kept.projectId = projects.groupProjectId(group.id, current: group.projectId)
                return kept
            }
    }

    // An undo. Each listed group takes the parent, project and order it had, checked as the library stands after
    // all of them and saved in one write. A move through `mutateGroup` takes the project of the parent it lands in.
    internal func restorePlacements(_ placements: [UUID: ConnectionGroupPlacement]) throws {
        let groups = loadGroups()
        guard !storeIsUnreadable else { throw GroupStorageError.storeUnreadable }
        var restored = groups
        for index in restored.indices {
            guard let placement = placements[restored[index].id] else { continue }
            restored[index].parentId = placement.parentId
            restored[index].projectId = placement.projectId
            restored[index].sortOrder = placement.sortOrder
        }
        guard restored != groups else { return }
        try validatePlacements(in: restored, was: groups)
        guard saveGroups(restored) else { throw GroupStorageError.storeUnreadable }
        notifyChanged()
    }

    private func validatePlacements(in restored: [ConnectionGroup], was groups: [ConnectionGroup]) throws {
        let before = projectScope(of: groups)
        let after = projectScope(of: restored)
        let stored = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newCycles = LibraryGroupGraph.cyclicGroupIds(in: restored)
            .subtracting(LibraryGroupGraph.cyclicGroupIds(in: groups))
        guard newCycles.isEmpty else { throw GroupStorageError.wouldCreateCycle }

        for group in restored {
            let id = group.id
            if group.parentId != stored[id]?.parentId {
                if let parentId = group.parentId, stored[parentId] == nil { throw GroupStorageError.groupNotFound }
                guard after.graph.depth(of: id) + after.graph.maxDescendantDepth(of: id)
                    <= LibraryGroupGraph.maxNestingDepth else { throw GroupStorageError.depthExceeded }
            }
            let parentId = after.graph.parentId(of: id)
            let arrived = parentId != before.graph.parentId(of: id)
                || (parentId == nil && after.effectiveProjectId(ofGroupId: id) != before.effectiveProjectId(ofGroupId: id))
            guard arrived else { continue }
            let clash = after.siblingGroupId(
                named: group.name,
                parentId: parentId,
                projectId: after.storedProjectId(ofGroupId: id),
                in: restored,
                excluding: [id]
            )
            if clash != nil { throw GroupStorageError.duplicateName(group.name) }
        }
    }

    // MARK: - Projects

    // The stored project of each listed group. A group that is not listed keeps what it stores.
    @discardableResult
    internal func applyProjectChanges(_ changes: [UUID: UUID?]) -> Bool {
        guard !changes.isEmpty else { return true }
        var groups = loadGroups()
        guard !storeIsUnreadable else { return false }
        for index in groups.indices {
            if let projectId = changes[groups[index].id] {
                groups[index].projectId = projectId
            }
        }
        return saveGroups(groups)
    }

    // A group inside another moves to the top level, since only a top-level group carries a project.
    internal func moveGroups(_ ids: [UUID], toProject projectId: UUID?) throws {
        var groups = loadGroups()
        guard !storeIsUnreadable else { throw GroupStorageError.storeUnreadable }
        let scope = projectScope(of: groups)
        let target = scope.resolved(projectId)
        let existing = Set(groups.map(\.id))
        var seen: Set<UUID> = []
        let moving = ids.filter { id in
            existing.contains(id) && seen.insert(id).inserted
                && (scope.graph.parentId(of: id) != nil || scope.effectiveProjectId(ofGroupId: id) != target)
        }
        guard !moving.isEmpty else { return }
        let movingSet = Set(moving)
        try validateNames(ofArriving: moving, parentId: nil, scope: scope, in: groups) { _ in target }
        var nextOrder = LibraryOrdering.nextSortOrder(
            after: groups.filter { scope.graph.parentId(of: $0.id) == nil && !movingSet.contains($0.id) }.map(\.sortOrder)
        )
        for index in groups.indices where movingSet.contains(groups[index].id) {
            if groups[index].parentId != nil {
                groups[index].parentId = nil
                groups[index].sortOrder = nextOrder
                nextOrder += 1
            }
            groups[index].projectId = target
        }
        guard saveGroups(groups) else { throw GroupStorageError.storeUnreadable }
        notifyChanged()
    }

    /// Matches inside this write rather than in the plan, so a group a sync pull added between
    /// preview and import is reused instead of duplicated.
    internal func ensureGroupPaths(_ paths: [[PathComponent]]) throws -> [UUID?] {
        guard paths.contains(where: { !$0.isEmpty }) else { return paths.map { _ in nil } }
        var groups = loadGroups()
        guard !storeIsUnreadable else { throw GroupStorageError.storeUnreadable }

        // A top-level group is matched inside the project the path names, so an import never files a
        // connection under another project's group of the same name.
        let scope = projectScope(of: groups)
        let existing = groups.map { group in
            PathNode(
                id: group.id,
                name: group.name,
                parentId: group.parentId,
                scope: group.parentId == nil ? scope.effectiveProjectId(ofGroupId: group.id) : nil
            )
        }
        let resolved = PathTreeResolver.resolve(paths, existing: existing)
        guard !resolved.created.isEmpty else { return resolved.leaves }

        for node in resolved.created {
            let sortOrder = LibraryOrdering.nextSortOrder(
                after: groups.filter { $0.parentId == node.parentId }.map(\.sortOrder)
            )
            groups.append(ConnectionGroup(
                id: node.id,
                name: node.name,
                color: node.color.map(ConnectionColor.init(storedValue:)) ?? .none,
                iconName: LibrarySymbolCatalog.normalizedName(node.iconName),
                parentId: node.parentId,
                sortOrder: sortOrder,
                projectId: node.parentId == nil ? node.scope : nil
            ))
        }
        guard saveGroups(groups) else { throw GroupStorageError.storeUnreadable }
        notifyChanged()
        return resolved.leaves
    }

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

    private struct SiblingName: Hashable {
        let projectId: UUID?
        let name: String
    }

    // Groups moved in together are excluded from the siblings, so they are checked against each other too.
    private func validateNames(
        ofArriving ids: [UUID],
        parentId: UUID?,
        scope: LibraryProjectScope,
        in groups: [ConnectionGroup],
        projectId: (ConnectionGroup) -> UUID?
    ) throws {
        let arriving = Set(ids)
        var taken: Set<SiblingName> = []
        for id in ids {
            guard let group = groups.first(where: { $0.id == id }) else { continue }
            let project = projectId(group)
            let clash = scope.siblingGroupId(
                named: group.name, parentId: parentId, projectId: project, in: groups, excluding: arriving
            )
            let name = SiblingName(
                projectId: parentId == nil ? scope.resolved(project) : nil,
                name: LibraryProjectName.folded(group.name)
            )
            guard clash == nil, taken.insert(name).inserted else {
                throw GroupStorageError.duplicateName(group.name)
            }
        }
    }

    // At the top level a name is taken only inside one project.
    private func validateUniqueName(
        _ group: ConnectionGroup,
        excluding ids: Set<UUID>,
        in groups: [ConnectionGroup]
    ) throws {
        let clash = projectScope(of: groups).siblingGroupId(
            named: group.name,
            parentId: group.parentId,
            projectId: group.projectId,
            in: groups,
            excluding: ids
        )
        guard clash == nil else { throw GroupStorageError.duplicateName(group.name) }
    }

    private func projectScope(of groups: [ConnectionGroup]) -> LibraryProjectScope {
        LibraryProjectScope(groups: groups, projectIds: projectIdsProvider())
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
