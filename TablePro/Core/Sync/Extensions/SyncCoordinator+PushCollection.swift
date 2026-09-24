import CloudKit
import Foundation
import os
import TableProSyncTransport

struct SyncPushBatch {
    var records: [CKRecord] = []
    var deletions: [CKRecord.ID] = []

    var uniqueDeletions: [CKRecord.ID] {
        Array(Set(deletions))
    }
}

extension SyncCoordinator {
    func collectPushBatch(
        snapshot: SyncEditSnapshot,
        settings: SyncSettings,
        zoneID: CKRecordZone.ID
    ) async -> SyncPushBatch {
        var batch = SyncPushBatch()

        if settings.syncConnections {
            let storage = services.connectionStorage
            await collectRecords(of: .connection, snapshot: snapshot, into: &batch, zoneID: zoneID) {
                let connections = storage.loadConnections()
                return storage.lastLoadFailed ? nil : connections
            } record: { (connection: DatabaseConnection) -> CKRecord? in
                guard !connection.localOnly else { return nil }
                let recordID = SyncRecordMapper.recordID(type: .connection, id: connection.id.uuidString, in: zoneID)
                return SyncRecordMapper.toCKRecord(connection, in: zoneID, base: recordCache.record(for: recordID))
            }
        }

        if settings.syncGroupsAndTags {
            let groupStorage = services.groupStorage
            await collectRecords(of: .group, snapshot: snapshot, into: &batch, zoneID: zoneID) {
                let groups = groupStorage.loadGroups()
                return groupStorage.storeIsUnreadable ? nil : groups
            } record: { (group: ConnectionGroup) in SyncRecordMapper.toCKRecord(group, in: zoneID) }

            let tagStorage = services.tagStorage
            await collectRecords(of: .tag, snapshot: snapshot, into: &batch, zoneID: zoneID) {
                let tags = tagStorage.loadTags()
                return tagStorage.storeIsUnreadable ? nil : tags
            } record: { (tag: ConnectionTag) in SyncRecordMapper.toCKRecord(tag, in: zoneID) }
        }

        if settings.syncSSHProfiles {
            let storage = services.sshProfileStorage
            await collectRecords(of: .sshProfile, snapshot: snapshot, into: &batch, zoneID: zoneID) {
                let profiles = storage.loadProfiles()
                return storage.lastLoadFailed ? nil : profiles
            } record: { (profile: SSHProfile) in SyncRecordMapper.toCKRecord(profile, in: zoneID) }
        }

        if settings.syncCredentialProfiles {
            let storage = services.credentialProfileStorage
            await collectRecords(of: .credentialProfile, snapshot: snapshot, into: &batch, zoneID: zoneID) {
                let profiles = storage.loadProfiles()
                return storage.lastLoadFailed ? nil : profiles
            } record: { (profile: CredentialProfile) in SyncRecordMapper.toCKRecord(profile, in: zoneID) }
        }

        if settings.syncSettings {
            collectSettings(snapshot: snapshot, into: &batch, zoneID: zoneID)
        }

        if settings.syncTableFavorites {
            collectTableFavorites(snapshot: snapshot, into: &batch, zoneID: zoneID)
        }

        if settings.syncDatabaseFavorites {
            collectDatabaseFavorites(snapshot: snapshot, into: &batch, zoneID: zoneID)
        }

        if settings.syncSQLFavorites {
            await collectSQLFavorites(snapshot: snapshot, into: &batch, zoneID: zoneID)
        }

        return batch
    }

    private func collectRecords<Record: Identifiable>(
        of type: SyncRecordType,
        snapshot: SyncEditSnapshot,
        into batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID,
        loaded: () async -> [Record]?,
        record: (Record) -> CKRecord?
    ) async where Record.ID == UUID {
        appendTombstones(of: type, to: &batch, zoneID: zoneID)
        let dirtyIds = snapshot.dirtyIds(for: type)
        guard !dirtyIds.isEmpty, let records = await loaded() else { return }

        var pushable: Set<String> = []
        for item in records where dirtyIds.contains(item.id.uuidString) {
            let id = item.id.uuidString
            guard !pushable.contains(id), let built = record(item) else { continue }
            pushable.insert(id)
            batch.records.append(built)
        }
        discardUnpushable(type, dirtyIds: dirtyIds, pushable: pushable)
    }

    private func discardUnpushable(_ type: SyncRecordType, dirtyIds: Set<String>, pushable: Set<String>) {
        let unpushable = dirtyIds.subtracting(pushable)
        guard !unpushable.isEmpty else { return }
        Self.logger.info(
            "Dropping \(unpushable.count, privacy: .public) \(type.rawValue, privacy: .public) marks this Mac cannot push"
        )
        changeTracker.discardDirty(type, ids: Array(unpushable))
    }

    private func appendTombstones(of type: SyncRecordType, to batch: inout SyncPushBatch, zoneID: CKRecordZone.ID) {
        for tombstone in metadataStorage.tombstones(for: type) {
            batch.deletions.append(SyncRecordMapper.recordID(type: type, id: tombstone.id, in: zoneID))
        }
    }

    private func collectSettings(snapshot: SyncEditSnapshot, into batch: inout SyncPushBatch, zoneID: CKRecordZone.ID) {
        for category in snapshot.dirtyIds(for: .settings) {
            guard let data = settingsData(for: category) else { continue }
            batch.records.append(SyncRecordMapper.toCKRecord(category: category, settingsData: data, in: zoneID))
        }
    }

    private func collectTableFavorites(
        snapshot: SyncEditSnapshot,
        into batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID
    ) {
        appendTombstones(of: .tableFavorite, to: &batch, zoneID: zoneID)
        let dirtyIds = snapshot.dirtyIds(for: .tableFavorite)
        guard !dirtyIds.isEmpty else { return }
        for entry in services.favoriteTablesStorage.loadFavorites()
        where dirtyIds.contains(FavoriteTablesStorage.syncId(for: entry)) {
            batch.records.append(SyncRecordMapper.toCKRecord(favoriteEntry: entry, in: zoneID))
        }
    }

    /// A connection the user marked local only never reaches iCloud, and neither do the database
    /// names hanging off it. Tombstones are not filtered: a deletion only ever removes something,
    /// and a connection can be marked local only after its favorites were already pushed.
    private func collectDatabaseFavorites(
        snapshot: SyncEditSnapshot,
        into batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID
    ) {
        appendTombstones(of: .favoriteDatabase, to: &batch, zoneID: zoneID)
        let dirtyIds = snapshot.dirtyIds(for: .favoriteDatabase)
        guard !dirtyIds.isEmpty else { return }
        let localOnlyIds = Set(services.connectionStorage.loadConnections().filter(\.localOnly).map(\.id))
        for entry in services.favoriteDatabasesStorage.loadFavorites()
        where dirtyIds.contains(FavoriteDatabasesStorage.syncId(for: entry))
            && !localOnlyIds.contains(entry.connectionId) {
            batch.records.append(SyncRecordMapper.toCKRecord(favoriteDatabase: entry, in: zoneID))
        }
    }

    private func collectSQLFavorites(
        snapshot: SyncEditSnapshot,
        into batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID
    ) async {
        let manager = services.sqlFavoriteManager
        await collectRecords(of: .favorite, snapshot: snapshot, into: &batch, zoneID: zoneID) {
            await manager.favoritesForSync()
        } record: { (favorite: SQLFavorite) in SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: zoneID) }

        await collectRecords(of: .favoriteFolder, snapshot: snapshot, into: &batch, zoneID: zoneID) {
            await manager.foldersForSync()
        } record: { (folder: SQLFavoriteFolder) in SyncRecordMapper.toCKRecord(sqlFavoriteFolder: folder, in: zoneID) }
    }
}
