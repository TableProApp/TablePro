import CloudKit
import Foundation
import Observation
import os
import TableProModels
import TableProSync
import TableProSyncTransport

@MainActor @Observable
final class IOSSyncCoordinator {
    typealias LibraryState = (connections: [DatabaseConnection], groups: [ConnectionGroup], tags: [ConnectionTag])

    private struct EditKey: Hashable {
        let type: SyncRecordType
        let id: String
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "Sync")

    var status: SyncStatus = .idle
    var lastSyncDate: Date?

    @ObservationIgnored private let metadata: SyncMetadataStorage
    @ObservationIgnored private let recordCache: SyncRecordCache
    @ObservationIgnored private let makeTransport: () -> any IOSSyncTransport
    @ObservationIgnored private var transport: (any IOSSyncTransport)?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var needsResync = false
    @ObservationIgnored private var editGenerations: [EditKey: Int] = [:]

    @ObservationIgnored var onConnectionsChanged: (([DatabaseConnection]) -> Void)?
    @ObservationIgnored var onGroupsChanged: (([ConnectionGroup]) -> Void)?
    @ObservationIgnored var onTagsChanged: (([ConnectionTag]) -> Void)?
    @ObservationIgnored var getCurrentState: (() -> LibraryState?)?

    /// Where the record cache lives, resolved by the app because the package cannot see it.
    ///
    /// The path is the one the package used to pick for itself, so a cache written by an earlier build is
    /// still found rather than silently abandoned and re-fetched.
    private static var recordCacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("TablePro/SyncRecordCache", isDirectory: true)
    }

    init(
        metadata: SyncMetadataStorage = SyncMetadataStorage(),
        recordCache: SyncRecordCache = SyncRecordCache(
            directory: IOSSyncCoordinator.recordCacheDirectory,
            defaults: .standard
        ),
        makeTransport: @escaping () -> any IOSSyncTransport = { CloudKitSyncEngine() }
    ) {
        self.metadata = metadata
        self.recordCache = recordCache
        self.makeTransport = makeTransport
    }

    private func currentTransport() -> any IOSSyncTransport {
        if let transport { return transport }
        let created = makeTransport()
        transport = created
        return created
    }

    // MARK: - Sync

    func sync(isRetry: Bool = false) async {
        guard isRetry || status != .syncing else {
            needsResync = true
            return
        }
        guard getCurrentState?() != nil else { return }
        status = .syncing
        defer { drainResyncIfNeeded() }

        do {
            let transport = currentTransport()
            guard try await transport.accountStatus() == .available else {
                status = .error(.accountUnavailable)
                return
            }

            try await transport.ensureZoneExists()
            let remoteChanges = try await pull(using: transport)
            let connCount = remoteChanges.changedConnections.count
            let groupCount = remoteChanges.changedGroups.count
            let tagCount = remoteChanges.changedTags.count
            Self.logger.info("Pulled \(connCount) connections, \(groupCount) groups, \(tagCount) tags")

            guard applyRemoteChanges(remoteChanges) else {
                status = .idle
                return
            }

            try await push(using: transport)

            if let newToken = remoteChanges.newToken {
                metadata.saveToken(newToken)
            }

            metadata.lastSyncDate = Date()
            lastSyncDate = metadata.lastSyncDate
            status = .idle
        } catch let error as SyncError where error == .tokenExpired {
            guard !isRetry else {
                status = .error(.tokenExpired)
                return
            }
            metadata.saveToken(nil)
            await sync(isRetry: true)
        } catch {
            status = .error(SyncError.from(error))
        }
    }

    // MARK: - Token Reset

    func resetSyncToken() async {
        debounceTask?.cancel()
        metadata.saveToken(nil)
        recordCache.removeAll()
        Self.logger.info("Sync token cleared; forcing full pull from iCloud")
        await sync()
    }

    // MARK: - Dirty / Tombstone Tracking

    func markDirty(_ connectionId: UUID) {
        markDirty(connectionId.uuidString, type: .connection)
    }

    func markDeleted(_ connectionId: UUID) {
        metadata.addTombstone(connectionId.uuidString, type: .connection)
    }

    func markDirtyGroup(_ groupId: UUID) {
        markDirty(groupId.uuidString, type: .group)
    }

    func markDeletedGroup(_ groupId: UUID) {
        metadata.addTombstone(groupId.uuidString, type: .group)
    }

    func markDirtyTag(_ tagId: UUID) {
        markDirty(tagId.uuidString, type: .tag)
    }

    func markDeletedTag(_ tagId: UUID) {
        metadata.addTombstone(tagId.uuidString, type: .tag)
    }

    private func markDirty(_ id: String, type: SyncRecordType) {
        editGenerations[EditKey(type: type, id: id), default: 0] += 1
        metadata.markDirty(id, type: type)
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
            await sync()
        }
    }

    // MARK: - Apply

    private func applyRemoteChanges(_ remote: PullChanges) -> Bool {
        guard let state = getCurrentState?() else { return false }
        onConnectionsChanged?(mergeConnections(local: state.connections, remote: remote))
        onGroupsChanged?(mergeGroups(local: state.groups, remote: remote))
        onTagsChanged?(mergeTags(local: state.tags, remote: remote))
        return true
    }

    // MARK: - Push

    private func push(using transport: any IOSSyncTransport) async throws {
        let zoneID = await transport.currentZoneID
        guard let state = getCurrentState?() else { return }
        let generationsAtPush = editGenerations
        var allRecords: [CKRecord] = []
        var allDeletions: [CKRecord.ID] = []

        let dirtyConnIDs = metadata.dirtyIds(for: .connection)
        for connection in state.connections where dirtyConnIDs.contains(connection.id.uuidString) {
            let recordID = SyncRecordMapper.recordID(type: .connection, id: connection.id.uuidString, in: zoneID)
            if let existing = recordCache.record(for: recordID) {
                SyncRecordMapper.updateRecord(existing, with: connection)
                allRecords.append(existing)
            } else {
                allRecords.append(SyncRecordMapper.toRecord(connection, zoneID: zoneID))
            }
        }

        for tombstone in metadata.tombstones(for: .connection) {
            allDeletions.append(SyncRecordMapper.recordID(type: .connection, id: tombstone.id, in: zoneID))
        }

        let dirtyGroupIDs = metadata.dirtyIds(for: .group)
        for group in state.groups where dirtyGroupIDs.contains(group.id.uuidString) {
            let recordID = SyncRecordMapper.recordID(type: .group, id: group.id.uuidString, in: zoneID)
            if let existing = recordCache.record(for: recordID) {
                SyncRecordMapper.updateRecord(existing, with: group)
                allRecords.append(existing)
            } else {
                allRecords.append(SyncRecordMapper.toRecord(group, zoneID: zoneID))
            }
        }

        for tombstone in metadata.tombstones(for: .group) {
            allDeletions.append(SyncRecordMapper.recordID(type: .group, id: tombstone.id, in: zoneID))
        }

        let dirtyTagIDs = metadata.dirtyIds(for: .tag)
        for tag in state.tags where dirtyTagIDs.contains(tag.id.uuidString) {
            let recordID = SyncRecordMapper.recordID(type: .tag, id: tag.id.uuidString, in: zoneID)
            if let existing = recordCache.record(for: recordID) {
                SyncRecordMapper.updateRecord(existing, with: tag)
                allRecords.append(existing)
            } else {
                allRecords.append(SyncRecordMapper.toRecord(tag, zoneID: zoneID))
            }
        }

        for tombstone in metadata.tombstones(for: .tag) {
            allDeletions.append(SyncRecordMapper.recordID(type: .tag, id: tombstone.id, in: zoneID))
        }

        guard !allRecords.isEmpty || !allDeletions.isEmpty else { return }

        let outcome = try await transport.push(records: allRecords, deletions: allDeletions)

        recordCache.store(Array(outcome.savedRecords.values))
        recordCache.remove(Array(outcome.deletedRecordIDs))

        for recordID in outcome.savedRecords.keys {
            guard let parsed = SyncRecordMapper.parse(recordName: recordID.recordName) else { continue }
            let key = EditKey(type: parsed.type, id: parsed.id)
            guard editGenerations[key] == generationsAtPush[key] else { continue }
            editGenerations[key] = nil
            metadata.removeDirty(parsed.id, type: parsed.type)
        }

        for recordID in outcome.deletedRecordIDs {
            guard let parsed = SyncRecordMapper.parse(recordName: recordID.recordName) else { continue }
            metadata.removeTombstone(parsed.id, type: parsed.type)
        }

        guard outcome.hasFailures else { return }

        for (recordID, failure) in outcome.failures {
            Self.logger.error("iCloud rejected \(recordID.recordName): \(failure.message)")
        }

        throw SyncError.pushRejected(
            count: outcome.failures.count,
            detail: outcome.failures.values.first?.message ?? ""
        )
    }

    // MARK: - Pull

    private struct PullChanges {
        var changedConnections: [DatabaseConnection] = []
        var deletedConnectionIDs: Set<UUID> = []
        var changedGroups: [ConnectionGroup] = []
        var deletedGroupIDs: Set<UUID> = []
        var changedTags: [ConnectionTag] = []
        var deletedTagIDs: Set<UUID> = []
        var newToken: CKServerChangeToken?
    }

    private func pull(using transport: any IOSSyncTransport) async throws -> PullChanges {
        let token = metadata.loadToken()
        let result = try await transport.pull(since: token)

        var changes = PullChanges()
        changes.newToken = result.newToken

        recordCache.store(result.changedRecords)
        recordCache.remove(result.deletedRecordIDs)

        for record in result.changedRecords {
            switch record.recordType {
            case SyncRecordType.connection.rawValue:
                if let connection = SyncRecordMapper.toConnection(record) {
                    changes.changedConnections.append(connection)
                }
            case SyncRecordType.group.rawValue:
                if let group = SyncRecordMapper.toGroup(record) {
                    changes.changedGroups.append(group)
                }
            case SyncRecordType.tag.rawValue:
                if let tag = SyncRecordMapper.toTag(record) {
                    changes.changedTags.append(tag)
                }
            default:
                break
            }
        }

        for recordID in result.deletedRecordIDs {
            guard let parsed = SyncRecordType.parse(recordName: recordID.recordName),
                  let uuid = UUID(uuidString: parsed.id) else { continue }
            switch parsed.type {
            case .connection:
                changes.deletedConnectionIDs.insert(uuid)
            case .group:
                changes.deletedGroupIDs.insert(uuid)
            case .tag:
                changes.deletedTagIDs.insert(uuid)
            default:
                break
            }
        }

        return changes
    }

    // MARK: - Merge

    private func mergeConnections(local: [DatabaseConnection], remote: PullChanges) -> [DatabaseConnection] {
        merge(
            local: local,
            changed: remote.changedConnections,
            deleted: remote.deletedConnectionIDs,
            dirtyIds: metadata.dirtyIds(for: .connection)
        )
    }

    private func mergeGroups(local: [ConnectionGroup], remote: PullChanges) -> [ConnectionGroup] {
        merge(
            local: local,
            changed: remote.changedGroups,
            deleted: remote.deletedGroupIDs,
            dirtyIds: metadata.dirtyIds(for: .group)
        )
    }

    private func mergeTags(local: [ConnectionTag], remote: PullChanges) -> [ConnectionTag] {
        merge(
            local: local,
            changed: remote.changedTags,
            deleted: remote.deletedTagIDs,
            dirtyIds: metadata.dirtyIds(for: .tag)
        )
    }

    private func merge<Item: Identifiable & Equatable>(
        local: [Item],
        changed: [Item],
        deleted: Set<UUID>,
        dirtyIds: Set<String>
    ) -> [Item] where Item.ID == UUID {
        var result = local.filter { !deleted.contains($0.id) }
        for remoteItem in changed where !deleted.contains(remoteItem.id) {
            guard let index = result.firstIndex(where: { $0.id == remoteItem.id }) else {
                result.append(remoteItem)
                continue
            }
            guard !dirtyIds.contains(remoteItem.id.uuidString), result[index] != remoteItem else { continue }
            result[index] = remoteItem
        }
        return result
    }
}
