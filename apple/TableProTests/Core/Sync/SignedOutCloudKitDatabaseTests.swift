import CloudKit
import Foundation
@testable import TablePro
import TableProFFI
import TableProSyncTransport
import Testing

struct SignedOutCloudKitDatabaseTests {
    @Test("A device profile's CloudKit has no iCloud account, so its engine never reaches the person's zone")
    func everyCallIsSignedOut() async throws {
        let database = SignedOutCloudKitDatabase()
        let zone = CKRecordZone.ID(zoneName: "TableProSync", ownerName: CKCurrentUserDefaultName)

        let status = try await database.accountStatus()
        #expect(status == .noAccount)
        #expect(CloudKitFailureMapping.account(status) == .NoAccount)
        await #expect(throws: CKError.self) { try await database.userRecordName() }
        await #expect(throws: CKError.self) { try await database.saveZone(zone) }
        await #expect(throws: CKError.self) { try await database.fetchChanges(in: zone, since: nil) }
        await #expect(throws: CKError.self) { try await database.modifyRecords(saving: [], deleting: []) }
    }
}
