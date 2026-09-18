import CloudKit
import Combine
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

    private(set) var status: SyncStatus
    var lastSyncDate: Date?

    @ObservationIgnored private let metadata: SyncMetadataStorage
    @ObservationIgnored private let recordCache: SyncRecordCache
    @ObservationIgnored private let makeTransport: () -> any IOSSyncTransport
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private var transport: (any IOSSyncTransport)?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var runningSync: Task<Void, Never>?
    @ObservationIgnored private var needsResync = false
    @ObservationIgnored private var statusGeneration = 0
    @ObservationIgnored private var editGenerations: [EditKey: Int] = [:]
    @ObservationIgnored private var accountChangeObservation: AnyCancellable?

    @ObservationIgnored var onConnectionsChanged: (([DatabaseConnection]) -> Void)?
    @ObservationIgnored var onGroupsChanged: (([ConnectionGroup]) -> Void)?
    @ObservationIgnored var onTagsChanged: (([ConnectionTag]) -> Void)?
    @ObservationIgnored var getCurrentState: (() -> LibraryState?)?

    private static var recordCacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("TablePro/SyncRecordCache", isDirectory: true)
    }

    init(
        metadata: SyncMetadataStorage = SyncMetadataStorage(userDefaults: .standard),
        recordCache: SyncRecordCache = SyncRecordCache(
            directory: IOSSyncCoordinator.recordCacheDirectory,
            defaults: .standard
        ),
        makeTransport: @escaping () -> any IOSSyncTransport = { CloudKitSyncEngine() },
        isEnabled: @escaping () -> Bool = { AppPreferences.isCloudSyncEnabled },
        notificationCenter: NotificationCenter = .default
    ) {
        self.metadata = metadata
        self.recordCache = recordCache
        self.makeTransport = makeTransport
        self.isEnabled = isEnabled
        self.status = isEnabled() ? .idle : .disabled(.userDisabled)
        self.lastSyncDate = metadata.lastSyncDate
        accountChangeObservation = notificationCenter.publisher(for: .CKAccountChanged)
            .sink { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.scheduleSyncAfterChange()
                }
            }
    }

    private func currentTransport() -> any IOSSyncTransport {
        if let transport { return transport }
        let created = makeTransport()
        transport = created
        return created
    }

    var hasCompletedFirstSync: Bool {
        lastSyncDate != nil
    }

    func accountStatus() async -> CKAccountStatus {
        do {
            return try await currentTransport().accountStatus()
        } catch {
            Self.logger.warning("iCloud account status unavailable: \(error.localizedDescription, privacy: .public)")
            return .couldNotDetermine
        }
    }

    // MARK: - Enable / Disable

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            debounceTask?.cancel()
            debounceTask = nil
            needsResync = false
            metadata.lastSyncDate = nil
            lastSyncDate = nil
            decide(.disabled(.userDisabled))
            return
        }
        decide(.idle)
        guard runningSync == nil else {
            needsResync = true
            return
        }
        Task { await sync() }
    }

    // MARK: - Sync

    func sync() async {
        guard isEnabled() else {
            if status != .disabled(.userDisabled) {
                decide(.disabled(.userDisabled))
            }
            return
        }
        if let runningSync {
            await runningSync.value
            return
        }
        let run = Task { await performSync() }
        runningSync = run
        await run.value
    }

    private func performSync() async {
        defer {
            runningSync = nil
            drainResyncIfNeeded()
        }
        guard getCurrentState?() != nil else { return }
        let generation = decide(.syncing)
        await attempt(generation: generation, isRetry: false)
    }

    private func attempt(generation: Int, isRetry: Bool) async {
        do {
            let transport = currentTransport()
            guard try await transport.accountStatus() == .available else {
                settle(.error(.accountUnavailable), from: generation)
                return
            }

            let accountId = try await transport.currentAccountId()
            guard generation == statusGeneration else { return }
            adoptAccount(accountId)

            try await transport.ensureZoneExists()
            let remoteChanges = try await pull(using: transport)
            guard generation == statusGeneration else { return }
            let connCount = remoteChanges.changedConnections.count
            let groupCount = remoteChanges.changedGroups.count
            let tagCount = remoteChanges.changedTags.count
            Self.logger.info("Pulled \(connCount) connections, \(groupCount) groups, \(tagCount) tags")

            guard applyRemoteChanges(remoteChanges) else {
                settle(.idle, from: generation)
                return
            }

            guard generation == statusGeneration else { return }
            try await push(using: transport)

            guard generation == statusGeneration else { return }
            if let newToken = remoteChanges.newToken {
                metadata.saveToken(newToken)
            }
            metadata.lastSyncDate = Date()
            lastSyncDate = metadata.lastSyncDate
            settle(.idle, from: generation)
        } catch let error as SyncError where error == .tokenExpired {
            guard !isRetry else {
                settle(.error(.tokenExpired), from: generation)
                return
            }
            metadata.saveToken(nil)
            await attempt(generation: generation, isRetry: true)
        } catch {
            settle(.error(SyncError.from(error)), from: generation)
        }
    }

    private func adoptAccount(_ accountId: String) {
        switch metadata.adoptAccount(accountId) {
        case .firstSeen, .unchanged:
            return
        case .switched:
            Self.logger.notice("The iCloud account changed, so sync starts over and pending edits go to the new account")
        case .previousAccountUnknown:
            Self.logger.notice("An earlier build synced without recording its iCloud account, so sync starts over once")
        }
        recordCache.removeAll()
        lastSyncDate = nil
    }

    @discardableResult
    private func decide(_ outcome: SyncStatus) -> Int {
        statusGeneration += 1
        status = outcome
        return statusGeneration
    }

    private func settle(_ outcome: SyncStatus, from generation: Int) {
        guard generation == statusGeneration else {
            Self.logger.info("Discarding a sync outcome the status moved on from")
            return
        }
        status = outcome
    }

    // MARK: - Dirty / Tombstone Tracking

    func markDirty(_ connectionId: UUID) {
        markDirty(connectionId.uuidString, type: .connection)
    }

    func markDeleted(_ connectionId: UUID) {
        addTombstone(connectionId.uuidString, type: .connection)
    }

    func markDirtyGroup(_ groupId: UUID) {
        markDirty(groupId.uuidString, type: .group)
    }

    func markDeletedGroup(_ groupId: UUID) {
        addTombstone(groupId.uuidString, type: .group)
    }

    func markDirtyTag(_ tagId: UUID) {
        markDirty(tagId.uuidString, type: .tag)
    }

    func markDeletedTag(_ tagId: UUID) {
        addTombstone(tagId.uuidString, type: .tag)
    }

    private func markDirty(_ id: String, type: SyncRecordType) {
        editGenerations[EditKey(type: type, id: id), default: 0] += 1
        metadata.markDirty(id, type: type)
    }

    private func addTombstone(_ id: String, type: SyncRecordType) {
        metadata.addTombstone(id, type: type)
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
        guard isEnabled() else {
            debounceTask = nil
            return
        }
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            guard runningSync == nil else {
                needsResync = true
                return
            }
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
        for connection in state.connections
            where connection.participatesInSync && dirtyConnIDs.contains(connection.id.uuidString) {
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

        var outcome = try await transport.push(records: allRecords, deletions: allDeletions)
        outcome.acceptMissingDeletions(of: allDeletions)

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
