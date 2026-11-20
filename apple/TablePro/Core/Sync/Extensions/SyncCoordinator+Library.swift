import CloudKit
import Foundation
import TableProSyncTransport

extension SyncCoordinator {
    func applyRemoteGroup(_ record: CKRecord, tombstoneIds: Set<String>) -> RemoteApplyOutcome {
        let readsProject = isProjectSyncWritable()
        guard var remoteGroup = SyncRecordMapper.toGroup(record, readsProject: readsProject) else { return .skipped }
        if tombstoneIds.contains(remoteGroup.id.uuidString) { return .skipped }
        // Until a record can carry a project, membership is this Mac's own and a pull leaves it.
        if !readsProject {
            remoteGroup.projectId = services.groupStorage.group(for: remoteGroup.id)?.projectId
        }

        return services.groupStorage.applyRemoteGroup(remoteGroup)
    }

    func applyRemoteProject(_ record: CKRecord, tombstoneIds: Set<String>) -> RemoteApplyOutcome {
        guard let remoteProject = SyncRecordMapper.toProject(record) else { return .skipped }
        if tombstoneIds.contains(remoteProject.id.uuidString) { return .skipped }

        return services.projectStorage.applyRemoteProject(remoteProject)
    }

    @discardableResult
    func applyRemoteTag(_ record: CKRecord, tombstoneIds: Set<String>) -> RemoteApplyOutcome {
        guard let remoteTag = SyncRecordMapper.toTag(record) else { return .skipped }
        if tombstoneIds.contains(remoteTag.id.uuidString) { return .skipped }

        return services.tagStorage.applyRemoteTag(remoteTag)
    }
}
