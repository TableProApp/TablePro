import CloudKit
import Foundation
import TableProSyncTransport

nonisolated protocol IOSSyncTransport: Sendable {
    var currentZoneID: CKRecordZone.ID { get async }
    func accountStatus() async throws -> CKAccountStatus
    func currentAccountId() async throws -> String
    func ensureZoneExists() async throws
    func pull(since token: CKServerChangeToken?) async throws -> PullResult
    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome
    func fetch(recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord]
}

extension CloudKitSyncEngine: IOSSyncTransport {}
