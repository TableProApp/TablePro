import CloudKit
import Foundation
import TableProModels
import TableProSync
import TableProSyncTransport

extension IOSSyncCoordinator {
    struct PullChanges {
        var changedConnections: [DatabaseConnection] = []
        var deletedConnectionIDs: Set<UUID> = []
        var changedGroups: [ConnectionGroup] = []
        var deletedGroupIDs: Set<UUID> = []
        var changedTags: [ConnectionTag] = []
        var deletedTagIDs: Set<UUID> = []
        var savedQueries = SavedQueryRemoteChanges()

        init(_ result: PullResult) {
            for record in result.changedRecords {
                switch record.recordType {
                case SyncRecordType.connection.rawValue:
                    if let connection = SyncRecordMapper.toConnection(record) {
                        changedConnections.append(connection)
                    }
                case SyncRecordType.group.rawValue:
                    if let group = SyncRecordMapper.toGroup(record) {
                        changedGroups.append(group)
                    }
                case SyncRecordType.tag.rawValue:
                    if let tag = SyncRecordMapper.toTag(record) {
                        changedTags.append(tag)
                    }
                case SyncRecordType.favorite.rawValue:
                    if let query = SyncRecordMapper.toSavedQuery(record) {
                        savedQueries.changedQueries.append(query)
                    }
                case SyncRecordType.favoriteFolder.rawValue:
                    if let folder = SyncRecordMapper.toSavedQueryFolder(record) {
                        savedQueries.changedFolders.append(folder)
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
                    deletedConnectionIDs.insert(uuid)
                case .group:
                    deletedGroupIDs.insert(uuid)
                case .tag:
                    deletedTagIDs.insert(uuid)
                case .favorite:
                    savedQueries.deletedQueryIds.insert(uuid)
                case .favoriteFolder:
                    savedQueries.deletedFolderIds.insert(uuid)
                default:
                    break
                }
            }
        }
    }
}
