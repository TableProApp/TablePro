import CloudKit
import Foundation
import os
import TableProSyncTransport

// The CloudKit operations iOS runs for sync, each checked against the organization's managed configuration as it
// stands, not as the app last saw it (P1-I3, core ADR 0055): before it starts, so no batch of an upload, fetch, zone
// change, subscription or account read reaches CloudKit once iCloud is taken away, and again before its answer is used,
// so what an operation in flight brought back is not applied after that.
nonisolated final class PolicyCheckedCloudKitDatabase: CloudKitDatabase, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PolicyCheckedCloudKitDatabase")

    private let base: any CloudKitDatabase
    private let isAllowed: @Sendable () -> Bool

    init(base: any CloudKitDatabase = LiveCloudKitDatabase(), isAllowed: @escaping @Sendable () -> Bool) {
        self.base = base
        self.isAllowed = isAllowed
    }

    private func admit() throws {
        guard isAllowed() else {
            Self.logger.notice("The organization turned iCloud off, so nothing more reaches CloudKit")
            throw CancellationError()
        }
    }

    private func checked<Value>(_ operation: () async throws -> Value) async throws -> Value {
        try admit()
        let value = try await operation()
        try admit()
        return value
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await checked { try await base.accountStatus() }
    }

    func userRecordName() async throws -> String {
        try await checked { try await base.userRecordName() }
    }

    func saveZone(_ zone: CKRecordZone.ID) async throws {
        try await checked { try await base.saveZone(zone) }
    }

    func deleteZone(_ zone: CKRecordZone.ID) async throws {
        try await checked { try await base.deleteZone(zone) }
    }

    func saveSubscription(_ subscription: CKSubscription) async throws {
        try await checked { try await base.saveSubscription(subscription) }
    }

    func fetchChanges(in zone: CKRecordZone.ID, since token: CKServerChangeToken?) async throws -> CloudKitChangesPage {
        try await checked { try await base.fetchChanges(in: zone, since: token) }
    }

    func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        try await checked { try await base.fetchRecords(ids) }
    }

    func modifyRecords(saving records: [CKRecord], deleting ids: [CKRecord.ID]) async throws -> CloudKitModifyResults {
        try await checked { try await base.modifyRecords(saving: records, deleting: ids) }
    }
}
