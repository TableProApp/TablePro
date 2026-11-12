import CloudKit
import Foundation
import TableProSyncTransport

// A deletion of a category this Mac does not sync is passed by the change token and never sent again, so its
// record name is kept until the category is read.
extension SyncCoordinator {
    // Deleting a profile removes keychain secrets no pull can bring back, so a late deletion never does it.
    static let typesNeverDeletedLate: Set<SyncRecordType> = [.sshProfile, .credentialProfile]

    struct DeferredDeletions {
        var due: [CKRecord.ID] = []
        var settled: Set<String> = []
    }

    func deferredDeletions(dueIn result: PullResult, settings: SyncSettings, zoneID: CKRecordZone.ID) -> DeferredDeletions {
        let deferred = metadataStorage.deferredDeletions
        guard !deferred.isEmpty else { return DeferredDeletions() }
        // A record the server sends again was saved after its deletion.
        let live = Set(result.changedRecords.map(\.recordID.recordName))
        var deletions = DeferredDeletions(settled: deferred.intersection(live))
        for name in deferred.subtracting(live) {
            guard let parsed = SyncRecordType.parse(recordName: name) else {
                deletions.settled.insert(name)
                continue
            }
            guard settings.syncs(parsed.type) else { continue }
            deletions.settled.insert(name)
            let editedHere = changeTracker.dirtyRecords(for: parsed.type).contains(parsed.id)
            guard !editedHere, !Self.typesNeverDeletedLate.contains(parsed.type) else { continue }
            deletions.due.append(SyncRecordMapper.recordID(type: parsed.type, id: parsed.id, in: zoneID))
        }
        return deletions
    }

    func settleDeferredDeletions(_ deletions: DeferredDeletions, after result: PullResult, settings: SyncSettings) {
        let skipped = result.deletedRecordIDs.map(\.recordName).filter { name in
            SyncRecordType.parse(recordName: name).map { !settings.syncs($0.type) } == true
        }
        guard !skipped.isEmpty || !deletions.settled.isEmpty else { return }
        metadataStorage.deferredDeletions = metadataStorage.deferredDeletions
            .subtracting(deletions.settled)
            .union(skipped)
    }
}
