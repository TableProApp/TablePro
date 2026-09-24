import CloudKit
import Foundation
import TableProSyncTransport

protocol SyncTransport: Sendable {
    var currentZoneID: CKRecordZone.ID { get async }
    func accountStatus() async throws -> CKAccountStatus
    func currentAccountId() async throws -> String
    func ensureZoneExists() async throws
    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome
    func pull(since token: CKServerChangeToken?) async throws -> PullResult
}

extension CloudKitSyncEngine: SyncTransport {}
