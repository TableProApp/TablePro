import CloudKit
import Foundation
@testable import TableProMobile
import TableProSyncTransport

// Answers every pull with the records it holds and saves every push, recording both.
actor RecordingSyncTransport: IOSSyncTransport {
    let currentZoneID = CKRecordZone.ID(zoneName: "RecordingZone", ownerName: CKCurrentUserDefaultName)
    private var remoteRecords: [CKRecord]
    private var remoteDeletions: [CKRecord.ID]
    private var newToken: CKServerChangeToken?
    private(set) var pushedRecords: [CKRecord] = []
    private(set) var pushedDeletions: [CKRecord.ID] = []
    private(set) var pullCount = 0

    init(
        remoteRecords: [CKRecord] = [],
        remoteDeletions: [CKRecord.ID] = [],
        newToken: CKServerChangeToken? = nil
    ) {
        self.remoteRecords = remoteRecords
        self.remoteDeletions = remoteDeletions
        self.newToken = newToken
    }

    func answerPulls(with records: [CKRecord], deletions: [CKRecord.ID] = []) {
        remoteRecords = records
        remoteDeletions = deletions
    }

    func accountStatus() async throws -> CKAccountStatus {
        .available
    }

    func currentAccountId() async throws -> String {
        "recording-account"
    }

    func ensureZoneExists() async throws {}

    func pull(since token: CKServerChangeToken?) async throws -> PullResult {
        pullCount += 1
        return PullResult(changedRecords: remoteRecords, deletedRecordIDs: remoteDeletions, newToken: newToken)
    }

    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome {
        pushedRecords.append(contentsOf: records)
        pushedDeletions.append(contentsOf: deletions)
        return PushOutcome(
            savedRecords: Dictionary(records.map { ($0.recordID, $0) }) { _, last in last },
            deletedRecordIDs: Set(deletions)
        )
    }

    // CKServerChangeToken has no public initializer, so a test token is decoded from an archive that names its class.
    static func makeChangeToken() throws -> CKServerChangeToken {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("CKServerChangeToken", for: RecordingChangeTokenArchive.self)
        archiver.encode(RecordingChangeTokenArchive(), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        guard let token = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: archiver.encodedData
        ) else {
            throw CKError(.internalError)
        }
        return token
    }
}

@objc(RecordingSyncTransportChangeTokenArchive)
private final class RecordingChangeTokenArchive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {}
}
