import CloudKit
import Foundation
import os
import TableProSyncTransport

struct SyncPushBatch {
    var edits: [SyncRecordEdit] = []
    var deletions: [CKRecord.ID] = []
    var supersededTombstones: Set<SyncRecordIdentity> = []

    var records: [CKRecord] {
        edits.map(\.record)
    }

    var editsByRecordID: [CKRecord.ID: SyncRecordEdit] {
        Dictionary(edits.map { ($0.recordID, $0) }, uniquingKeysWith: { _, last in last })
    }

    var uniqueDeletions: [CKRecord.ID] {
        Array(Set(deletions))
    }
}

enum SyncPushDisposition {
    case push(SyncRecordEdit)
    case hold
    case drop
}

private struct BuiltRecord {
    let id: String
    let edit: SyncRecordEdit
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
        case .push(let edit):
            built.append(BuiltRecord(id: id, edit: edit))
        case .hold:
            heldIds.insert(id)
        case .drop:
            return
        }
        resolvedIds.insert(id)
    }
}

extension SyncCoordinator {
    // iPhone and iPad dial the record's tunnel with a linked profile's password, so a linked connection goes up with
    // the server the profile names now, as this Mac dials it, never an imported or stale copy of it.
    static func syncedTunnel(of connection: DatabaseConnection, profiles: SSHProfileStorage) -> DatabaseConnection {
        profiles.refreshingLinkedProfile(connection)
    }

    // Built on a copy of the cached record, so the edit compares against the untouched one.
    private func edit<Field: SyncSchemaField>(
        _ field: Field.Type,
        _ type: SyncRecordType,
        id: String,
        in zoneID: CKRecordZone.ID,
        build: (CKRecord?) -> CKRecord,
        reread: (CKRecord) -> CKRecord? = { _ in nil }
    ) -> SyncRecordEdit {
        let base = recordCache.record(for: SyncRecordMapper.recordID(type: type, id: id, in: zoneID))
        return SyncRecordEdit(
            field,
            record: build(base?.copy() as? CKRecord),
            base: base,
            baseAsWritten: base.flatMap(reread)
        )
    }

    func collectPushBatch(
        snapshot: SyncEditSnapshot,
        boundary: SyncBoundary,
        zoneID: CKRecordZone.ID
    ) async -> SyncPushBatch {
        var batch = SyncPushBatch()

        if boundary.includes(.connection) {
            let storage = services.connectionStorage
            let profiles = services.sshProfileStorage
            let routePublisher = storage.sshRoutePublisherId
            await collectRecords(of: .connection, snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID) {
                let connections = storage.loadConnections()
                return storage.lastLoadFailed ? nil : connections
            } disposition: { (connection: DatabaseConnection) in
                guard connection.participatesInSync else { return .drop }
                let recordID = SyncRecordMapper.recordID(type: .connection, id: connection.id.uuidString, in: zoneID)
                return .push(SyncRecordMapper.connectionEdit(
                    Self.syncedTunnel(of: connection, profiles: profiles),
                    in: zoneID,
                    base: recordCache.record(for: recordID),
                    publisher: routePublisher
                ))
            }
        }

        if boundary.includes(.group) {
            let groupStorage = services.groupStorage
            await collectRecords(of: .group, snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID) {
                let groups = groupStorage.loadGroups()
                return groupStorage.storeIsUnreadable ? nil : groups
            } disposition: { (group: ConnectionGroup) in
                .push(edit(ConnectionGroupSyncField.self, .group, id: group.id.uuidString, in: zoneID) { base in
                    SyncRecordMapper.toCKRecord(group, in: zoneID, base: base)
                } reread: { base in
                    SyncRecordMapper.toGroup(base).map { SyncRecordMapper.toCKRecord($0, in: zoneID) }
                })
            }
        }

        if boundary.includes(.tag) {
            let tagStorage = services.tagStorage
            await collectRecords(of: .tag, snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID) {
                let tags = tagStorage.loadTags()
                return tagStorage.storeIsUnreadable ? nil : tags
            } disposition: { (tag: ConnectionTag) in
                .push(edit(ConnectionTagSyncField.self, .tag, id: tag.id.uuidString, in: zoneID) { base in
                    SyncRecordMapper.toCKRecord(tag, in: zoneID, base: base)
                } reread: { base in
                    SyncRecordMapper.toTag(base).map { SyncRecordMapper.toCKRecord($0, in: zoneID) }
                })
            }
        }

        if boundary.includes(.sshProfile) {
            let storage = services.sshProfileStorage
            await collectRecords(of: .sshProfile, snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID) {
                let profiles = storage.loadProfiles()
                return storage.lastLoadFailed ? nil : profiles
            } disposition: { (profile: SSHProfile) in
                .push(edit(SSHProfileSyncField.self, .sshProfile, id: profile.id.uuidString, in: zoneID) { base in
                    SyncRecordMapper.toCKRecord(profile, in: zoneID, base: base)
                } reread: { base in
                    (try? SyncRecordMapper.toSSHProfile(base)).map { SyncRecordMapper.toCKRecord($0, in: zoneID) }
                })
            }
        }

        if boundary.includes(.credentialProfile) {
            let storage = services.credentialProfileStorage
            await collectRecords(
                of: .credentialProfile, snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID
            ) {
                let profiles = storage.loadProfiles()
                return storage.lastLoadFailed ? nil : profiles
            } disposition: { (profile: CredentialProfile) in
                .push(edit(CredentialProfileSyncField.self, .credentialProfile, id: profile.id.uuidString, in: zoneID) { base in
                    SyncRecordMapper.toCKRecord(profile, in: zoneID, base: base)
                } reread: { base in
                    (try? SyncRecordMapper.toCredentialProfile(base)).map { SyncRecordMapper.toCKRecord($0, in: zoneID) }
                })
            }
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
        batch.edits.append(contentsOf: collected.built.map(\.edit))
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
            return .push(SyncRecordMapper.settingsEdit(
                category: category,
                settingsData: data,
                in: zoneID,
                base: recordCache.record(for: SyncRecordMapper.recordID(type: .settings, id: category, in: zoneID))
            ))
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
        let collected = collectTableFavorites(favorites, dirtyIds: dirtyIds, boundary: boundary, zoneID: zoneID)
        append(.tableFavorite, dirtyIds: dirtyIds, collected: collected, boundary: boundary, into: &batch, zoneID: zoneID)
    }

    private func collectTableFavorites(
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
                    edit(FavoriteTableSyncField.self, .tableFavorite, id: recordId, in: zoneID) { base in
                        SyncRecordMapper.toCKRecord(favoriteEntry: entry, recordId: recordId, in: zoneID, base: base)
                    }
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
            return .push(edit(
                FavoriteDatabaseSyncField.self, .favoriteDatabase, id: FavoriteDatabasesStorage.syncId(for: entry), in: zoneID
            ) { base in
                SyncRecordMapper.toCKRecord(favoriteDatabase: entry, in: zoneID, base: base)
            } reread: { base in
                (try? SyncRecordMapper.favoriteDatabase(from: base)).map { SyncRecordMapper.toCKRecord(favoriteDatabase: $0, in: zoneID) }
            })
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
            return .push(edit(TableFolderSyncField.self, .tableFolder, id: folder.id.uuidString, in: zoneID) { base in
                SyncRecordMapper.toCKRecord(tableFolder: folder, in: zoneID, base: base)
            } reread: { base in
                (try? SyncRecordMapper.tableFolder(from: base)).map { SyncRecordMapper.toCKRecord(tableFolder: $0, in: zoneID) }
            })
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
            return .push(edit(TableFolderItemSyncField.self, .tableFolderItem, id: item.syncId, in: zoneID) { base in
                SyncRecordMapper.toCKRecord(tableFolderItem: item, in: zoneID, base: base)
            } reread: { base in
                (try? SyncRecordMapper.tableFolderItem(from: base)).map { SyncRecordMapper.toCKRecord(tableFolderItem: $0, in: zoneID) }
            })
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
                return .push(edit(SQLFavoriteSyncField.self, .favorite, id: favorite.id.uuidString, in: zoneID) { base in
                    SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: zoneID, base: base)
                } reread: { base in
                    (try? SyncRecordMapper.sqlFavorite(from: base)).map { SyncRecordMapper.toCKRecord(sqlFavorite: $0, in: zoneID) }
                })
            }
        }

        if boundary.includes(.favoriteFolder) {
            await collectRecords(
                of: .favoriteFolder, snapshot: snapshot, boundary: boundary, into: &batch, zoneID: zoneID
            ) {
                await manager.foldersForSync()
            } disposition: { (folder: SQLFavoriteFolder) in
                guard boundary.includes(.favoriteFolder, owner: folder.connectionId) else { return .hold }
                return .push(edit(SQLFavoriteFolderSyncField.self, .favoriteFolder, id: folder.id.uuidString, in: zoneID) { base in
                    SyncRecordMapper.toCKRecord(sqlFavoriteFolder: folder, in: zoneID, base: base)
                } reread: { base in
                    (try? SyncRecordMapper.sqlFavoriteFolder(from: base)).map {
                        SyncRecordMapper.toCKRecord(sqlFavoriteFolder: $0, in: zoneID)
                    }
                })
            }
        }
    }
}
