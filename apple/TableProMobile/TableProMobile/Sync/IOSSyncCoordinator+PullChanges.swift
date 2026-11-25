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
        var changedProjects: [ConnectionProject] = []
        var deletedProjectIDs: Set<UUID> = []
        var savedQueries = SavedQueryRemoteChanges()

        // `local` is the library the records land on. While project sync is off no record carries a project, so
        // each pulled connection and group keeps the one its copy here stores, and a project record or deletion
        // waits for the full fetch the first run that reads them makes, as on the Mac.
        init(_ result: PullResult, over local: LibraryState? = nil, projectSyncWritable: Bool = SyncSchemaGate.isProjectSyncWritable) {
            let localConnections = Dictionary(
                (local?.connections ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let localGroups = Dictionary((local?.groups ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for record in result.changedRecords {
                let localId = SyncRecordType.parse(recordName: record.recordID.recordName).flatMap { UUID(uuidString: $0.id) }
                switch record.recordType {
                case SyncRecordType.connection.rawValue:
                    if let connection = SyncRecordMapper.pulledConnection(
                        record,
                        over: localId.flatMap { localConnections[$0] },
                        projectSyncWritable: projectSyncWritable
                    ) {
                        changedConnections.append(connection)
                    }
                case SyncRecordType.group.rawValue:
                    if let group = SyncRecordMapper.pulledGroup(
                        record,
                        over: localId.flatMap { localGroups[$0] },
                        projectSyncWritable: projectSyncWritable
                    ) {
                        changedGroups.append(group)
                    }
                case SyncRecordType.project.rawValue:
                    if projectSyncWritable, let project = SyncRecordMapper.toProject(record) {
                        changedProjects.append(project)
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
                case .project:
                    if projectSyncWritable {
                        deletedProjectIDs.insert(uuid)
                    }
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
