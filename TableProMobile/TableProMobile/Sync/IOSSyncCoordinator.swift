//
//  IOSSyncCoordinator.swift
//  TableProMobile
//

import CloudKit
import Foundation
import Observation
import os
import TableProModels
import TableProSync

@MainActor @Observable
final class IOSSyncCoordinator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "Sync")

    var status: SyncStatus = .idle
    var lastSyncDate: Date?

    private var engine: CloudKitSyncEngine?
    private let metadata = SyncMetadataStorage()
    private var cachedRecords: [UUID: CKRecord] = [:]
    private var cachedGroupRecords: [UUID: CKRecord] = [:]
    private var cachedTagRecords: [UUID: CKRecord] = [:]

    private func getEngine() -> CloudKitSyncEngine {
        if let engine { return engine }
        let newEngine = CloudKitSyncEngine()
        engine = newEngine
        return newEngine
    }
    private var debounceTask: Task<Void, Never>?
    private var needsResync = false

    var onConnectionsChanged: (([DatabaseConnection]) -> Void)?
    var onGroupsChanged: (([ConnectionGroup]) -> Void)?
    var onTagsChanged: (([ConnectionTag]) -> Void)?
    var getCurrentState: (() -> (connections: [DatabaseConnection], groups: [ConnectionGroup], tags: [ConnectionTag]))?

    // MARK: - Sync

    func sync(
        localConnections: [DatabaseConnection],
        localGroups: [ConnectionGroup] = [],
        localTags: [ConnectionTag] = [],
        isRetry: Bool = false
    ) async {
        guard isRetry || status != .syncing else {
            needsResync = true
            return
        }
        status = .syncing
        defer { drainResyncIfNeeded() }

        do {
            let accountStatus = try await getEngine().accountStatus()
            guard accountStatus == .available else {
                status = .error("iCloud account not available")
                return
            }

            try await getEngine().ensureZoneExists()
            let remoteChanges = try await pull()
            let connCount = remoteChanges.changedConnections.count
            let groupCount = remoteChanges.changedGroups.count
            let tagCount = remoteChanges.changedTags.count
            Self.logger.info("Pulled \(connCount) connections, \(groupCount) groups, \(tagCount) tags")

            let mergedConnections = mergeConnections(local: localConnections, remote: remoteChanges)
            let mergedGroups = mergeGroups(local: localGroups, remote: remoteChanges)
            let mergedTags = mergeTags(local: localTags, remote: remoteChanges)

            try await push(
                localConnections: mergedConnections,
                localGroups: mergedGroups,
                localTags: mergedTags
            )

            onConnectionsChanged?(mergedConnections)
            onGroupsChanged?(mergedGroups)
            onTagsChanged?(mergedTags)

            metadata.lastSyncDate = Date()
            lastSyncDate = metadata.lastSyncDate
            status = .idle
        } catch let error as SyncError where error == .tokenExpired {
            guard !isRetry else {
                status = .error("Sync failed after token refresh")
                return
            }
            metadata.saveToken(nil)
            await sync(
                localConnections: localConnections,
                localGroups: localGroups,
                localTags: localTags,
                isRetry: true
            )
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Dirty / Tombstone Tracking

    func markDirty(_ connectionId: UUID) {
        metadata.markDirty(connectionId.uuidString, type: .connection)
    }

    func markDeleted(_ connectionId: UUID) {
        metadata.addTombstone(connectionId.uuidString, type: .connection)
    }

    func markDirtyGroup(_ groupId: UUID) {
        metadata.markDirty(groupId.uuidString, type: .group)
    }

    func markDeletedGroup(_ groupId: UUID) {
        metadata.addTombstone(groupId.uuidString, type: .group)
    }

    func markDirtyTag(_ tagId: UUID) {
        metadata.markDirty(tagId.uuidString, type: .tag)
    }

    func markDeletedTag(_ tagId: UUID) {
        metadata.addTombstone(tagId.uuidString, type: .tag)
    }

    private func drainResyncIfNeeded() {
        guard needsResync, status == .idle else {
            needsResync = false
            return
        }
        needsResync = false
        scheduleSyncAfterChange()
    }

    func scheduleSyncAfterChange() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            guard let state = getCurrentState?() else { return }
            await sync(
                localConnections: state.connections,
                localGroups: state.groups,
                localTags: state.tags
            )
        }
    }

    // MARK: - Push

    private func push(
        localConnections: [DatabaseConnection],
        localGroups: [ConnectionGroup],
        localTags: [ConnectionTag]
    ) async throws {
        let zoneID = await getEngine().currentZoneID
        var allRecords: [CKRecord] = []
        var allDeletions: [CKRecord.ID] = []

        // Dirty connections
        let dirtyConnIDs = metadata.dirtyIDs(for: .connection)
        for connection in localConnections where dirtyConnIDs.contains(connection.id.uuidString) {
            if let existing = cachedRecords[connection.id] {
                SyncRecordMapper.updateRecord(existing, with: connection)
                allRecords.append(existing)
            } else {
                allRecords.append(SyncRecordMapper.toRecord(connection, zoneID: zoneID))
            }
        }

        // Connection tombstones
        for tombstone in metadata.tombstones(for: .connection) {
            allDeletions.append(CKRecord.ID(recordName: "Connection_\(tombstone.id)", zoneID: zoneID))
        }

        // Dirty groups
        let dirtyGroupIDs = metadata.dirtyIDs(for: .group)
        for group in localGroups where dirtyGroupIDs.contains(group.id.uuidString) {
            if let existing = cachedGroupRecords[group.id] {
                SyncRecordMapper.updateRecord(existing, with: group)
                allRecords.append(existing)
            } else {
                allRecords.append(SyncRecordMapper.toRecord(group, zoneID: zoneID))
            }
        }

        // Group tombstones
        for tombstone in metadata.tombstones(for: .group) {
            allDeletions.append(CKRecord.ID(recordName: "Group_\(tombstone.id)", zoneID: zoneID))
        }

        // Dirty tags
        let dirtyTagIDs = metadata.dirtyIDs(for: .tag)
        for tag in localTags where dirtyTagIDs.contains(tag.id.uuidString) {
            if let existing = cachedTagRecords[tag.id] {
                SyncRecordMapper.updateRecord(existing, with: tag)
                allRecords.append(existing)
            } else {
                allRecords.append(SyncRecordMapper.toRecord(tag, zoneID: zoneID))
            }
        }

        // Tag tombstones
        for tombstone in metadata.tombstones(for: .tag) {
            allDeletions.append(CKRecord.ID(recordName: "Tag_\(tombstone.id)", zoneID: zoneID))
        }

        guard !allRecords.isEmpty || !allDeletions.isEmpty else { return }

        try await getEngine().push(records: allRecords, deletions: allDeletions)
        metadata.clearDirty(type: .connection)
        metadata.clearTombstones(type: .connection)
        metadata.clearDirty(type: .group)
        metadata.clearTombstones(type: .group)
        metadata.clearDirty(type: .tag)
        metadata.clearTombstones(type: .tag)
    }

    // MARK: - Pull

    private struct PullChanges {
        var changedConnections: [DatabaseConnection] = []
        var deletedConnectionIDs: Set<UUID> = []
        var changedGroups: [ConnectionGroup] = []
        var deletedGroupIDs: Set<UUID> = []
        var changedTags: [ConnectionTag] = []
        var deletedTagIDs: Set<UUID> = []
    }

    private func pull() async throws -> PullChanges {
        let token = metadata.loadToken()
        let result = try await getEngine().pull(since: token)

        if let newToken = result.newToken {
            metadata.saveToken(newToken)
        }

        var changes = PullChanges()

        for record in result.changedRecords {
            switch record.recordType {
            case SyncRecordType.connection.rawValue:
                if let connection = SyncRecordMapper.toConnection(record) {
                    cachedRecords[connection.id] = record
                    changes.changedConnections.append(connection)
                }
            case SyncRecordType.group.rawValue:
                if let group = SyncRecordMapper.toGroup(record) {
                    cachedGroupRecords[group.id] = record
                    changes.changedGroups.append(group)
                }
            case SyncRecordType.tag.rawValue:
                if let tag = SyncRecordMapper.toTag(record) {
                    cachedTagRecords[tag.id] = record
                    changes.changedTags.append(tag)
                }
            default:
                break
            }
        }

        for recordID in result.deletedRecordIDs {
            let name = recordID.recordName
            if name.hasPrefix("Connection_") {
                let uuidStr = String(name.dropFirst("Connection_".count))
                if let uuid = UUID(uuidString: uuidStr) {
                    changes.deletedConnectionIDs.insert(uuid)
                }
            } else if name.hasPrefix("Group_") {
                let uuidStr = String(name.dropFirst("Group_".count))
                if let uuid = UUID(uuidString: uuidStr) {
                    changes.deletedGroupIDs.insert(uuid)
                }
            } else if name.hasPrefix("Tag_") {
                let uuidStr = String(name.dropFirst("Tag_".count))
                if let uuid = UUID(uuidString: uuidStr) {
                    changes.deletedTagIDs.insert(uuid)
                }
            }
        }

        return changes
    }

    // MARK: - Merge

    // DatabaseConnection has no modifiedDate field, so we use CKRecord.modificationDate
    // from the cached record to determine which version is newer. Local changes are
    // tracked via dirty flags (markDirty), so if the local copy is dirty and the remote
    // record is older than the last sync, we keep local. Otherwise remote wins.

    private func mergeConnections(local: [DatabaseConnection], remote: PullChanges) -> [DatabaseConnection] {
        var result = local.filter { !remote.deletedConnectionIDs.contains($0.id) }
        let localMap = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        let dirtyIDs = metadata.dirtyIDs(for: .connection)

        for remoteConn in remote.changedConnections {
            if localMap[remoteConn.id] != nil {
                if let index = result.firstIndex(where: { $0.id == remoteConn.id }) {
                    if dirtyIDs.contains(remoteConn.id.uuidString) {
                        // Local has unsaved changes: keep local version so we push it later
                        continue
                    }
                    if result[index] == remoteConn {
                        // Content identical: skip overwrite to preserve any transient local state
                        continue
                    }
                    result[index] = remoteConn
                }
            } else if !remote.deletedConnectionIDs.contains(remoteConn.id) {
                result.append(remoteConn)
            }
        }

        return result
    }

    private func mergeGroups(local: [ConnectionGroup], remote: PullChanges) -> [ConnectionGroup] {
        var result = local.filter { !remote.deletedGroupIDs.contains($0.id) }
        let localMap = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        let dirtyIDs = metadata.dirtyIDs(for: .group)

        for remoteGroup in remote.changedGroups {
            if localMap[remoteGroup.id] != nil {
                if let index = result.firstIndex(where: { $0.id == remoteGroup.id }) {
                    if dirtyIDs.contains(remoteGroup.id.uuidString) {
                        continue
                    }
                    if result[index] == remoteGroup {
                        continue
                    }
                    result[index] = remoteGroup
                }
            } else if !remote.deletedGroupIDs.contains(remoteGroup.id) {
                result.append(remoteGroup)
            }
        }

        return result
    }

    private func mergeTags(local: [ConnectionTag], remote: PullChanges) -> [ConnectionTag] {
        var result = local.filter { !remote.deletedTagIDs.contains($0.id) }
        let localMap = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        let dirtyIDs = metadata.dirtyIDs(for: .tag)

        for remoteTag in remote.changedTags {
            if localMap[remoteTag.id] != nil {
                if let index = result.firstIndex(where: { $0.id == remoteTag.id }) {
                    if dirtyIDs.contains(remoteTag.id.uuidString) {
                        continue
                    }
                    if result[index] == remoteTag {
                        continue
                    }
                    result[index] = remoteTag
                }
            } else if !remote.deletedTagIDs.contains(remoteTag.id) {
                result.append(remoteTag)
            }
        }

        return result
    }
}
