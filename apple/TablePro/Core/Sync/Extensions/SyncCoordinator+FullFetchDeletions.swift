import CloudKit
import Foundation
import os
import TableProSyncTransport

// A full fetch lists the records a zone holds and never the ones it lost, so a deletion passed by an expired
// or cleared token is found by what the fetch no longer lists. A zone deleted and made again holds only
// records created after it was made, so a cached copy created no earlier than the oldest fetched record
// belongs to the zone this fetch read, and its absence from a complete fetch proves it was deleted there.
enum SyncFullFetchDeletions {
    struct Candidate: Equatable {
        let recordID: CKRecord.ID
        let cachedCreation: Date?
    }

    static func proven(
        candidates: [Candidate],
        fetchedNames: Set<String>,
        fetchedCreations: [Date]
    ) -> [CKRecord.ID] {
        guard let oldestFetched = fetchedCreations.min() else { return [] }
        return candidates.compactMap { candidate in
            guard !fetchedNames.contains(candidate.recordID.recordName),
                  let created = candidate.cachedCreation,
                  created >= oldestFetched
            else { return nil }
            return candidate.recordID
        }
    }
}

extension SyncCoordinator {
    func deletionsProvenByFullFetch(
        _ result: PullResult,
        settings: SyncSettings,
        zoneID: CKRecordZone.ID,
        pushed: Set<CKRecord.ID>
    ) async -> [CKRecord.ID] {
        let fetchedCreations = result.changedRecords.compactMap(recordCreationDate)
        guard result.unreadRecordIDs.isEmpty, !fetchedCreations.isEmpty else { return [] }
        let fetchedNames = Set(result.changedRecords.map(\.recordID.recordName))
        let boundary = syncBoundary(settings: settings)
        var candidates: [SyncFullFetchDeletions.Candidate] = []
        for (type, ids) in await localRecordIds()
            where settings.syncs(type) && !Self.typesNeverDeletedLate.contains(type) {
            let dirty = changeTracker.dirtyRecords(for: type)
            let tombstoned = Set(metadataStorage.tombstones(for: type).map(\.id))
            for id in ids where !dirty.contains(id) && !tombstoned.contains(id) {
                guard boundary.includes(type, owner: SyncBoundary.owner(ofRecordId: id, type: type)) else { continue }
                let recordID = SyncRecordMapper.recordID(type: type, id: id, in: zoneID)
                guard !fetchedNames.contains(recordID.recordName),
                      !pushed.contains(recordID),
                      let cached = recordCache.record(for: recordID)
                else { continue }
                candidates.append(.init(recordID: recordID, cachedCreation: recordCreationDate(cached)))
            }
        }
        let proven = SyncFullFetchDeletions.proven(
            candidates: candidates,
            fetchedNames: fetchedNames,
            fetchedCreations: fetchedCreations
        )
        if !proven.isEmpty {
            Self.logger.info("A full fetch no longer lists \(proven.count, privacy: .public) records this Mac holds; deleting them here")
        }
        return proven
    }

    // Only the settings records a deletion acts on are listed: column layouts and themes.
    private func localRecordIds() async -> [(type: SyncRecordType, ids: [String])] {
        let tableFolderIds = tableFolderSyncIds()
        var listed: [(type: SyncRecordType, ids: [String])] = [
            (.connection, services.connectionStorage.loadConnections().filter(\.participatesInSync).map { $0.id.uuidString }),
            (.group, services.groupStorage.loadGroups().map { $0.id.uuidString }),
            (.tag, services.tagStorage.loadTags().map { $0.id.uuidString }),
            (.tableFavorite, services.favoriteTablesStorage.loadFavorites().map { FavoriteTablesStorage.syncId(for: $0) }),
            (.favoriteDatabase, services.favoriteDatabasesStorage.loadFavorites().map { FavoriteDatabasesStorage.syncId(for: $0) }),
            (.tableFolder, tableFolderIds.folders),
            (.tableFolderItem, tableFolderIds.items),
            (
                .settings,
                columnLayouts().customizedStorageKeys().map { FileColumnLayoutPersister.syncCategory(for: $0) }
                    + themeCatalog.syncCategories
            )
        ]
        if let favorites = await services.sqlFavoriteManager.favoritesForSync() {
            listed.append((.favorite, favorites.map { $0.id.uuidString }))
        }
        if let folders = await services.sqlFavoriteManager.foldersForSync() {
            listed.append((.favoriteFolder, folders.map { $0.id.uuidString }))
        }
        return listed
    }
}
