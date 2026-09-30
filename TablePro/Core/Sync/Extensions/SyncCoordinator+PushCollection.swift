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

enum SyncPushDisposition {
    case push(CKRecord)
    case hold
    case drop
}

private struct BuiltRecord {
    let id: String
    let record: CKRecord
}

private struct CollectedRecords {
    private(set) var built: [BuiltRecord] = []
    private(set) var heldIds: Set<String> = []
    private var resolvedIds: Set<String> = []

    func hasResolved(_ id: String) -> Bool {
        resolvedIds.contains(id)
    }

    mutating func add(_ id: String, _ disposition: SyncPushDisposition) {
        switch disposition {
        case .push(let record):
            built.append(BuiltRecord(id: id, record: record))
        case .hold:
            heldIds.insert(id)
        case .drop:
            return
        }
        resolvedIds.insert(id)
    }
}

extension SyncCoordinator {
    func collectPushBatch(
        snapshot: SyncEditSnapshot,
        boundary: SyncBoundary,
        zoneID: CKRecordZone.ID
    ) async -> SyncPushBatch {
        var batch = SyncPushBatch()

        if boundary.includes(.connection) {
            let storage = services.connectionStorage
            await collectRecords(of: .connection, snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID) {
                let connections = storage.loadConnections()
                return storage.lastLoadFailed ? nil : connections
            } disposition: { (connection: DatabaseConnection) in
                guard connection.participatesInSync else { return .drop }
                let recordID = SyncRecordMapper.recordID(type: .connection, id: connection.id.uuidString, in: zoneID)
                return .push(SyncRecordMapper.toCKRecord(connection, in: zoneID, base: recordCache.record(for: recordID)))
            }
        }

        if boundary.includes(.group) {
            let groupStorage = services.groupStorage
            await collectRecords(of: .group, snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID) {
                let groups = groupStorage.loadGroups()
                return groupStorage.storeIsUnreadable ? nil : groups
            } disposition: { (group: ConnectionGroup) in .push(SyncRecordMapper.toCKRecord(group, in: zoneID)) }
        }

        if boundary.includes(.tag) {
            let tagStorage = services.tagStorage
            await collectRecords(of: .tag, snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID) {
                let tags = tagStorage.loadTags()
                return tagStorage.storeIsUnreadable ? nil : tags
            } disposition: { (tag: ConnectionTag) in .push(SyncRecordMapper.toCKRecord(tag, in: zoneID)) }
        }

        if boundary.includes(.sshProfile) {
            let storage = services.sshProfileStorage
            await collectRecords(of: .sshProfile, snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID) {
                let profiles = storage.loadProfiles()
                return storage.lastLoadFailed ? nil : profiles
            } disposition: { (profile: SSHProfile) in .push(SyncRecordMapper.toCKRecord(profile, in: zoneID)) }
        }

        if boundary.includes(.credentialProfile) {
            let storage = services.credentialProfileStorage
            await collectRecords(
                of: .credentialProfile, snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID
            ) {
                let profiles = storage.loadProfiles()
                return storage.lastLoadFailed ? nil : profiles
            } disposition: { (profile: CredentialProfile) in .push(SyncRecordMapper.toCKRecord(profile, in: zoneID)) }
        }

        if boundary.includes(.settings) {
            collectSettings(snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID)
        }

        if boundary.includes(.tableFavorite) {
            collectTableFavorites(snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID)
        }

        if boundary.includes(.favoriteDatabase) {
            collectDatabaseFavorites(snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID)
        }

        await collectSQLFavorites(snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID)

        if boundary.includes(.tableFolder) {
            collectTableFolders(snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID)
        }

        if boundary.includes(.tableFolderItem) {
            collectTableFolderItems(snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID)
        }

        return batch
    }

    private func collectRecords<Record: Identifiable>(
        of type: SyncRecordType,
        snapshot: SyncEditSnapshot,
        boundary: SyncBoundary,
        into batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID,
        loaded: () async -> [Record]?,
        disposition: (Record) -> SyncPushDisposition
    ) async where Record.ID == UUID {
        let dirtyIds = snapshot.dirtyIds(for: type)
        guard !dirtyIds.isEmpty else {
            append(type, dirtyIds: dirtyIds, collected: CollectedRecords(), boundary: boundary, into: &batch, zoneID: zoneID)
            return
        }
        let collected = await loaded().map { records in
            Self.collect(records, dirtyIds: dirtyIds, id: { $0.id.uuidString }, disposition: disposition)
        }
        append(type, dirtyIds: dirtyIds, collected: collected, boundary: boundary, into: &batch, zoneID: zoneID)
    }

    private static func collect<Item>(
        _ items: [Item],
        dirtyIds: Set<String>,
        id: (Item) -> String,
        disposition: (Item) -> SyncPushDisposition
    ) -> CollectedRecords {
        var collected = CollectedRecords()
        for item in items {
            let itemId = id(item)
            guard dirtyIds.contains(itemId), !collected.hasResolved(itemId) else { continue }
            collected.add(itemId, disposition(item))
        }
        return collected
    }

    private func append(
        _ type: SyncRecordType,
        dirtyIds: Set<String>,
        collected: CollectedRecords?,
        boundary: SyncBoundary,
        into batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID
    ) {
        guard let collected else {
            appendTombstones(of: type, sparing: dirtyIds, boundary: boundary, to: &batch, zoneID: zoneID)
            return
        }
        let pushable = Set(collected.built.map(\.id))
        batch.records.append(contentsOf: collected.built.map(\.record))
        discardUnpushable(type, dirtyIds: dirtyIds.subtracting(collected.heldIds), pushable: pushable)
        let superseded = appendTombstones(of: type, sparing: pushable, boundary: boundary, to: &batch, zoneID: zoneID)
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
        boundary: SyncBoundary,
        to batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID
    ) -> Set<String> {
        var spared: Set<String> = []
        var heldCount = 0
        for tombstone in metadataStorage.tombstones(for: type) {
            guard !sparedIds.contains(tombstone.id) else {
                spared.insert(tombstone.id)
                continue
            }
            guard boundary.includes(tombstone, of: type) else {
                heldCount += 1
                continue
            }
            batch.deletions.append(SyncRecordMapper.recordID(type: type, id: tombstone.id, in: zoneID))
        }
        if heldCount > 0 {
            Self.logger.info(
                "Held \(heldCount, privacy: .public) \(type.rawValue, privacy: .public) deletions of connections this Mac does not sync"
            )
        }
        return spared
    }

    private func collectSettings(
        snapshot: SyncEditSnapshot,
        boundary: SyncBoundary,
        into batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID
    ) {
        let dirtyIds = snapshot.dirtyIds(for: .settings)
        retireSettingsTombstonesOfLiveCategories(dirtyIds: dirtyIds)
        let collected = Self.collect(Array(dirtyIds), dirtyIds: dirtyIds, id: { $0 }) { category in
            let owner = SyncBoundary.owner(ofRecordId: category, type: .settings)
            guard boundary.includes(.settings, owner: owner) else { return .hold }
            guard let data = settingsData(for: category) else { return .drop }
            return .push(SyncRecordMapper.toCKRecord(category: category, settingsData: data, in: zoneID))
        }
        append(.settings, dirtyIds: dirtyIds, collected: collected, boundary: boundary, into: &batch, zoneID: zoneID)
    }

    private func retireSettingsTombstonesOfLiveCategories(dirtyIds: Set<String>) {
        let live = metadataStorage.tombstones(for: .settings)
            .map(\.id)
            .filter { !dirtyIds.contains($0) && settingsData(for: $0) != nil }
        for category in Set(live) {
            metadataStorage.removeTombstone(category, type: .settings)
        }
    }

    private func collectTableFavorites(
        snapshot: SyncEditSnapshot,
        boundary: SyncBoundary,
        into batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID
    ) {
        let dirtyIds = snapshot.dirtyIds(for: .tableFavorite)
        let favorites = dirtyIds.isEmpty ? [] : services.favoriteTablesStorage.loadFavorites()
        let collected = Self.collectTableFavorites(favorites, dirtyIds: dirtyIds, boundary: boundary, zoneID: zoneID)
        append(.tableFavorite, dirtyIds: dirtyIds, collected: collected, boundary: boundary, into: &batch, zoneID: zoneID)
    }

    private static func collectTableFavorites(
        _ favorites: Set<FavoriteTablesStorage.FavoriteEntry>,
        dirtyIds: Set<String>,
        boundary: SyncBoundary,
        zoneID: CKRecordZone.ID
    ) -> CollectedRecords {
        let claims = FavoriteTablesStorage.aliasClaims(in: favorites)
        var collected = CollectedRecords()
        for entry in favorites {
            var recordIds = [FavoriteTablesStorage.syncId(for: entry)]
            if let alias = FavoriteTablesStorage.legacyAlias(of: entry), claims[alias]?.count == 1 {
                recordIds.append(alias)
            }
            let admitted = boundary.includes(.tableFavorite, owner: entry.connectionId)
            for recordId in recordIds where dirtyIds.contains(recordId) {
                collected.add(recordId, admitted ? .push(
                    SyncRecordMapper.toCKRecord(favoriteEntry: entry, recordId: recordId, in: zoneID)
                ) : .hold)
            }
        }
        return collected
    }

    private func collectDatabaseFavorites(
        snapshot: SyncEditSnapshot,
        boundary: SyncBoundary,
        into batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID
    ) {
        let dirtyIds = snapshot.dirtyIds(for: .favoriteDatabase)
        let favorites = dirtyIds.isEmpty ? [] : services.favoriteDatabasesStorage.loadFavorites()
        let collected = Self.collect(
            Array(favorites),
            dirtyIds: dirtyIds,
            id: FavoriteDatabasesStorage.syncId(for:)
        ) { entry in
            guard boundary.includes(.favoriteDatabase, owner: entry.connectionId) else { return .hold }
            return .push(SyncRecordMapper.toCKRecord(favoriteDatabase: entry, in: zoneID))
        }
        append(.favoriteDatabase, dirtyIds: dirtyIds, collected: collected, boundary: boundary, into: &batch, zoneID: zoneID)
    }

    private func collectTableFolders(
        snapshot: SyncEditSnapshot,
        boundary: SyncBoundary,
        into batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID
    ) {
        let dirtyIds = snapshot.dirtyIds(for: .tableFolder)
        let storage = services.tableFolderStorage
        let loaded = dirtyIds.isEmpty ? [] : storage.allFolders()
        let collected = dirtyIds.isEmpty || storage.hasUnreadableDocuments ? nil : Self.collect(
            loaded,
            dirtyIds: dirtyIds,
            id: { $0.id.uuidString }
        ) { folder in
            guard boundary.includes(.tableFolder, owner: folder.scope.connectionId) else { return .hold }
            return .push(SyncRecordMapper.toCKRecord(tableFolder: folder, in: zoneID))
        }
        append(.tableFolder, dirtyIds: dirtyIds, collected: collected, boundary: boundary, into: &batch, zoneID: zoneID)
    }

    private func collectTableFolderItems(
        snapshot: SyncEditSnapshot,
        boundary: SyncBoundary,
        into batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID
    ) {
        let dirtyIds = snapshot.dirtyIds(for: .tableFolderItem)
        let storage = services.tableFolderStorage
        let loaded = dirtyIds.isEmpty ? [] : storage.allItems()
        let collected = dirtyIds.isEmpty || storage.hasUnreadableDocuments ? nil : Self.collect(
            loaded,
            dirtyIds: dirtyIds,
            id: \.syncId
        ) { item in
            guard boundary.includes(.tableFolderItem, owner: item.scope.connectionId) else { return .hold }
            return .push(SyncRecordMapper.toCKRecord(tableFolderItem: item, in: zoneID))
        }
        append(.tableFolderItem, dirtyIds: dirtyIds, collected: collected, boundary: boundary, into: &batch, zoneID: zoneID)
    }

    private func collectSQLFavorites(
        snapshot: SyncEditSnapshot,
        boundary: SyncBoundary,
        into batch: inout SyncPushBatch,
        zoneID: CKRecordZone.ID
    ) async {
        let manager = services.sqlFavoriteManager
        if boundary.includes(.favorite) {
            await collectRecords(of: .favorite, snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID) {
                await manager.favoritesForSync()
            } disposition: { (favorite: SQLFavorite) in
                guard boundary.includes(.favorite, owner: favorite.connectionId) else { return .hold }
                return .push(SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: zoneID))
            }
        }

        if boundary.includes(.favoriteFolder) {
            await collectRecords(
                of: .favoriteFolder, snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID
            ) {
                await manager.foldersForSync()
            } disposition: { (folder: SQLFavoriteFolder) in
                guard boundary.includes(.favoriteFolder, owner: folder.connectionId) else { return .hold }
                return .push(SyncRecordMapper.toCKRecord(sqlFavoriteFolder: folder, in: zoneID))
            }
        }
    }
}
