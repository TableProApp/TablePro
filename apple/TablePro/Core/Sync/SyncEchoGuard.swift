import CloudKit
import Foundation
import TableProSyncTransport

struct SyncEchoGuard: Sendable {
    static let typesMergedOnPull: Set<SyncRecordType> = [.connection]

    let snapshot: SyncEditSnapshot
    let savedRecords: [CKRecord.ID: SyncRecordIdentity]
    let deletedRecords: [CKRecord.ID: SyncRecordIdentity]
    // Every record the push saved, connections included, which a fetch right after it may not list yet.
    let pushedRecordIDs: Set<CKRecord.ID>
    private let savedIdentities: Set<SyncRecordIdentity>

    init(
        snapshot: SyncEditSnapshot,
        savedRecords: [CKRecord.ID: SyncRecordIdentity],
        deletedRecords: [CKRecord.ID: SyncRecordIdentity] = [:]
    ) {
        let guarded = savedRecords.filter { !Self.typesMergedOnPull.contains($0.value.type) }
        self.snapshot = snapshot
        self.pushedRecordIDs = Set(savedRecords.keys)
        self.savedRecords = guarded
        self.deletedRecords = deletedRecords
        self.savedIdentities = Set(guarded.values)
    }

    func withholdsDeletion(_ recordID: CKRecord.ID, tracker: SyncChangeTracker) -> Bool {
        guard let identity = deletedRecords[recordID] else { return false }
        return tracker.hasEdit(identity, since: snapshot)
    }

    func withholds(_ recordID: CKRecord.ID, tracker: SyncChangeTracker) -> Bool {
        guard let identity = savedRecords[recordID] else { return false }
        return tracker.hasEdit(identity, since: snapshot)
    }

    func withholds(_ type: SyncRecordType, id: String, tracker: SyncChangeTracker) -> Bool {
        let identity = SyncRecordIdentity(type: type, id: id)
        guard savedIdentities.contains(identity) else { return false }
        return tracker.hasEdit(identity, since: snapshot)
    }
}
