import CloudKit
import Foundation
import os
import TableProSyncTransport

struct SyncPushBatch {
    var records: [CKRecord] = []
    var deletions: [CKRecord.ID] = []
    var supersededTombstones: Set<SyncRecordIdentity> = []

    var uniqueDeletions: [CKRecord.ID] {
        Array(Set(deletions))
    }
}

private struct BuiltRecord {
    let id: String
    let record: CKRecord
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
        let dirtyIds = snapshot.dirtyIds(for: type)
        guard !dirtyIds.isEmpty else {
            append(type, dirtyIds: dirtyIds, built: [], into: &batch, zoneID: zoneID)
            return
        }
        let built = await loaded().map { records in
            Self.build(records, dirtyIds: dirtyIds, id: { $0.id.uuidString }, record: record)
        }
        append(type, dirtyIds: dirtyIds, built: built, into: &batch, zoneID: zoneID)
    }

    private static func build<Item>(
        _ items: [Item],
        dirtyIds: Set<String>,
        id: (Item) -> String,
        record: (Item) -> CKRecord?
    ) -> [BuiltRecord] {
        var built: [BuiltRecord] = []
        var builtIds: Set<String> = []
        for item in items {
            let itemId = id(item)
            guard dirtyIds.contains(itemId), !builtIds.contains(itemId), let record = record(item) else { continue }
            builtIds.insert(itemId)
            built.append(BuiltRecord(id: itemId, record: record))
        }
        return built
    }

    private func append(
        _ type: SyncRecordType,
        dirtyIds: Set<String>,
        built: [BuiltRecord]?,
        retaining retainedIds: Set<String> = [],
        into batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID
    ) {
        guard let built else {
            appendTombstones(of: type, sparing: dirtyIds, to: &batch, zoneID: zoneID)
            return
        }
        let pushable = Set(built.map(\.id))
        batch.records.append(contentsOf: built.map(\.record))
        discardUnpushable(type, dirtyIds: dirtyIds.subtracting(retainedIds), pushable: pushable)
        let superseded = appendTombstones(of: type, sparing: pushable, to: &batch, zoneID: zoneID)
        batch.supersededTombstones.formUnion(superseded.map { SyncRecordIdentity(type: type, id: $0) })
    }

    private func discardUnpushable(_ type: SyncRecordType, dirtyIds: Set<String>, pushable: Set<String>) {
        let unpushable = dirtyIds.subtracting(pushable)
        guard !unpushable.isEmpty else { return }
        Self.logger.info(
            "Dropping \(unpushable.count, privacy: .public) \(type.rawValue, privacy: .public) marks this Mac cannot push"
        )
        changeTracker.discardDirty(type, ids: Array(unpushable))
    }

    @discardableResult
    private func appendTombstones(
        of type: SyncRecordType,
        sparing sparedIds: Set<String>,
        to batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID
    ) -> Set<String> {
        var spared: Set<String> = []
        for tombstone in metadataStorage.tombstones(for: type) {
            guard !sparedIds.contains(tombstone.id) else {
                spared.insert(tombstone.id)
                continue
            }
            batch.deletions.append(SyncRecordMapper.recordID(type: type, id: tombstone.id, in: zoneID))
        }
        return spared
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
        let dirtyIds = snapshot.dirtyIds(for: .tableFavorite)
        guard !dirtyIds.isEmpty else {
            append(.tableFavorite, dirtyIds: dirtyIds, built: [], into: &batch, zoneID: zoneID)
            return
        }
        let built = Self.buildTableFavorites(
            services.favoriteTablesStorage.loadFavorites(),
            dirtyIds: dirtyIds,
            zoneID: zoneID
        )
        append(.tableFavorite, dirtyIds: dirtyIds, built: built, into: &batch, zoneID: zoneID)
    }

    private static func buildTableFavorites(
        _ favorites: Set<FavoriteTablesStorage.FavoriteEntry>,
        dirtyIds: Set<String>,
        zoneID: CKRecordZone.ID
    ) -> [BuiltRecord] {
        let claims = FavoriteTablesStorage.aliasClaims(in: favorites)
        var built: [BuiltRecord] = []
        for entry in favorites {
            let currentId = FavoriteTablesStorage.syncId(for: entry)
            if dirtyIds.contains(currentId) {
                built.append(BuiltRecord(
                    id: currentId,
                    record: SyncRecordMapper.toCKRecord(favoriteEntry: entry, recordId: currentId, in: zoneID)
                ))
            }
            guard let alias = FavoriteTablesStorage.legacyAlias(of: entry),
                  dirtyIds.contains(alias),
                  claims[alias]?.count == 1 else { continue }
            built.append(BuiltRecord(
                id: alias,
                record: SyncRecordMapper.toCKRecord(favoriteEntry: entry, recordId: alias, in: zoneID)
            ))
        }
        return built
    }

    /// A connection the user marked local only never reaches iCloud, and neither do the database
    /// names hanging off it. Tombstones are not filtered: a deletion only ever removes something,
    /// and a connection can be marked local only after its favorites were already pushed.
    private func collectDatabaseFavorites(
        snapshot: SyncEditSnapshot,
        into batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID
    ) {
        let dirtyIds = snapshot.dirtyIds(for: .favoriteDatabase)
        guard !dirtyIds.isEmpty else {
            append(.favoriteDatabase, dirtyIds: dirtyIds, built: [], into: &batch, zoneID: zoneID)
            return
        }
        let localOnlyIds = Set(services.connectionStorage.loadConnections().filter(\.localOnly).map(\.id))
        let favorites = services.favoriteDatabasesStorage.loadFavorites()
        let withheld = favorites.filter { localOnlyIds.contains($0.connectionId) }
        let built = Self.build(
            Array(favorites.subtracting(withheld)),
            dirtyIds: dirtyIds,
            id: FavoriteDatabasesStorage.syncId(for:),
            record: { SyncRecordMapper.toCKRecord(favoriteDatabase: $0, in: zoneID) }
        )
        append(
            .favoriteDatabase,
            dirtyIds: dirtyIds,
            built: built,
            retaining: Set(withheld.map(FavoriteDatabasesStorage.syncId(for:))),
            into: &batch,
            zoneID: zoneID
        )
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
