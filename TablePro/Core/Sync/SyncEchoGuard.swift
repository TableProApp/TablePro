import CloudKit
import Foundation
import TableProSyncTransport

struct SyncEchoGuard: Sendable {
    static let typesMergedOnPull: Set<SyncRecordType> = [.connection]

    let snapshot: SyncEditSnapshot
    let savedRecords: [CKRecord.ID: SyncRecordIdentity]
    private let savedIdentities: Set<SyncRecordIdentity>

    init(snapshot: SyncEditSnapshot, savedRecords: [CKRecord.ID: SyncRecordIdentity]) {
        let guarded = savedRecords.filter { !Self.typesMergedOnPull.contains($0.value.type) }
        self.snapshot = snapshot
        self.savedRecords = guarded
        self.savedIdentities = Set(guarded.values)
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
