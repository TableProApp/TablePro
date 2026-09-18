import CloudKit
import Foundation
@testable import TableProMobile
import TableProSync
import TableProSyncTransport

struct UnreachableSyncTransport: IOSSyncTransport {
    var currentZoneID: CKRecordZone.ID {
        get async { CKRecordZone.ID(zoneName: "Unused", ownerName: CKCurrentUserDefaultName) }
    }

    func accountStatus() async throws -> CKAccountStatus {
        .noAccount
    }

    func currentAccountId() async throws -> String {
        throw CKError(.notAuthenticated)
    }

    func ensureZoneExists() async throws {}

    func pull(since token: CKServerChangeToken?) async throws -> PullResult {
        PullResult(changedRecords: [], deletedRecordIDs: [], newToken: nil)
    }

    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome {
        PushOutcome(savedRecords: [:], deletedRecordIDs: [])
    }
}
