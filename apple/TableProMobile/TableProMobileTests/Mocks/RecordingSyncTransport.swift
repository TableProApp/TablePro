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
    private(set) var fullFetchCount = 0
    private var answersOnlyFullFetches = false
    private var fetchable: [CKRecord.ID: CKRecord] = [:]
    private(set) var fetchedRecordIDs: [CKRecord.ID] = []
    private(set) var subscriptionSaves = 0
    private var subscriptionError: (any Error)?
    private var beforeAccountRead: (@Sendable () async -> Void)?
    private var beforePull: (@Sendable () async -> Void)?

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

    // A server nothing changed on: a pull from a token brings nothing, and only a full fetch lists the records.
    func answerOnlyFullFetches() {
        answersOnlyFullFetches = true
    }

    // Served to a fetch by id, as the server holds it.
    func serveOnFetch(_ record: CKRecord) {
        fetchable[record.recordID] = record
    }

    // Runs inside every account read, before any download starts.
    func holdAccountChecks(_ hold: @escaping @Sendable () async -> Void) {
        beforeAccountRead = hold
    }

    // Runs inside every pull, once it is counted.
    func holdPulls(_ hold: @escaping @Sendable () async -> Void) {
        beforePull = hold
    }

    func accountStatus() async throws -> CKAccountStatus {
        .available
    }

    func currentAccountId() async throws -> String {
        await beforeAccountRead?()
        return "recording-account"
    }

    func ensureZoneExists() async throws {}

    func failSubscriptionSaves(with error: (any Error)?) {
        subscriptionError = error
    }

    func saveSubscription() async throws {
        subscriptionSaves += 1
        if let subscriptionError {
            throw subscriptionError
        }
    }

    func pull(since token: CKServerChangeToken?) async throws -> PullResult {
        pullCount += 1
        await beforePull?()
        if token == nil {
            fullFetchCount += 1
        } else if answersOnlyFullFetches {
            return PullResult(changedRecords: [], deletedRecordIDs: [], newToken: newToken)
        }
        return PullResult(changedRecords: remoteRecords, deletedRecordIDs: remoteDeletions, newToken: newToken)
    }

    func fetch(recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord] {
        fetchedRecordIDs.append(contentsOf: recordIDs)
        return fetchable.filter { recordIDs.contains($0.key) }
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
