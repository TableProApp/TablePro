//
//  CloudKitSyncEngineTests.swift
//  TableProTests
//
//  Verifies the soft-dependency path: when the running process lacks the
//  iCloud entitlement, every CloudKit-touching method throws
//  SyncError.accountUnavailable instead of trapping. Tests skip themselves
//  when the test host happens to be signed with the entitlement (otherwise
//  they would hit the real CloudKit network or get unrelated errors).
//

import CloudKit
import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("CloudKitSyncEngine soft dependency")
struct CloudKitSyncEngineTests {
    private func skipIfEntitled() throws {
        try #require(!CloudKitSyncEngine.hasICloudEntitlement(), "Test host has the iCloud entitlement; skipping")
    }

    @Test("checkAccountStatus throws accountUnavailable without iCloud entitlement")
    func checkAccountStatusThrows() async throws {
        try skipIfEntitled()
        let engine = CloudKitSyncEngine()
        await #expect(throws: SyncError.accountUnavailable) {
            _ = try await engine.checkAccountStatus()
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
        let zoneID = await engine.zoneID
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
}
