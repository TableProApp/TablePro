import CloudKit
import Foundation
import Testing

@testable import TableProSyncTransport

@Suite(
    "CloudKitSyncEngine soft dependency",
    .disabled(if: CloudKitSyncEngine.hasICloudEntitlement(), "Test host has the iCloud entitlement")
)
struct CloudKitSyncEngineTests {
    private func skipIfEntitled() throws {
        try #require(!CloudKitSyncEngine.hasICloudEntitlement(), "Test host has the iCloud entitlement; skipping")
    }

    @Test("accountStatus throws accountUnavailable without iCloud entitlement")
    func accountStatusThrows() async throws {
        try skipIfEntitled()
        let engine = CloudKitSyncEngine()
        await #expect(throws: SyncError.accountUnavailable) {
            _ = try await engine.accountStatus()
        }
    }

    @Test("ensureZoneExists throws accountUnavailable without iCloud entitlement")
    func ensureZoneExistsThrows() async throws {
        try skipIfEntitled()
        let engine = CloudKitSyncEngine()
        await #expect(throws: SyncError.accountUnavailable) {
            try await engine.ensureZoneExists()
        }
    }

    @Test("push with non-empty input throws accountUnavailable without iCloud entitlement")
    func pushThrows() async throws {
        try skipIfEntitled()
        let engine = CloudKitSyncEngine()
        let zoneID = await engine.currentZoneID
        let record = CKRecord(recordType: "Test", recordID: CKRecord.ID(recordName: "test", zoneID: zoneID))
        await #expect(throws: SyncError.accountUnavailable) {
            try await engine.push(records: [record], deletions: [])
        }
    }

    @Test("push short-circuits without throwing when both inputs are empty")
    func pushEmptyShortCircuits() async throws {
        let engine = CloudKitSyncEngine()
        try await engine.push(records: [], deletions: [])
    }

    @Test("pull throws accountUnavailable without iCloud entitlement")
    func pullThrows() async throws {
        try skipIfEntitled()
        let engine = CloudKitSyncEngine()
        await #expect(throws: SyncError.accountUnavailable) {
            _ = try await engine.pull(since: nil)
        }
    }

    @Test("currentAccountId throws accountUnavailable without iCloud entitlement")
    func currentAccountIdThrows() async throws {
        try skipIfEntitled()
        let engine = CloudKitSyncEngine()
        await #expect(throws: SyncError.accountUnavailable) {
            _ = try await engine.currentAccountId()
        }
    }

    @Test("The sync zone name is stable")
    func zoneNameIsStable() async {
        let engine = CloudKitSyncEngine()
        let zoneID = await engine.currentZoneID
        #expect(zoneID.zoneName == CloudKitSyncEngine.zoneName)
        #expect(CloudKitSyncEngine.zoneName == "TableProSync")
    }
}
