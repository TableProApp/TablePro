import CloudKit
import Foundation
import os
import TableProFFI
@testable import TableProMobile
import TableProSyncTransport
import TableProTestSupport
import Testing

// P1-I3: once the organization takes iCloud away, no batch of an upload in flight reaches CloudKit, and nothing an
// operation brings back after that is used.
struct PolicyCheckedCloudKitDatabaseTests {
    private let held = HeldCloudKitDatabase()
    private let allowed = OSAllocatedUnfairLock(initialState: true)
    private let database: PolicyCheckedCloudKitDatabase
    private let transport: CloudKitCoreTransport

    init() {
        database = PolicyCheckedCloudKitDatabase(base: held) { [allowed] in allowed.withLock { $0 } }
        transport = CloudKitCoreTransport(database: database)
        transport.open()
    }

    private static func tag(_ name: String) -> CloudKitRecord {
        CloudKitRecord(recordType: "ConnectionTag", name: name, systemFields: nil, createdMs: nil, fields: [])
    }

    private func upload(_ name: String) async -> Bool {
        do {
            _ = try await transport.modify(account: "_alice", saves: [Self.tag(name)], deletes: [])
            return true
        } catch {
            return false
        }
    }

    @Test("An upload in flight sends no later batch once iCloud is taken away, and the batch's answer is not used")
    func aLaterBatchNeverReachesCloudKit() async throws {
        held.holdNextModify()
        let first = Task { await upload("Tag_A") }
        try await waitUntil { held.modifyStarted == 1 }

        allowed.withLock { $0 = false }
        held.releaseHeldModify()
        let firstAnswered = await first.value
        let secondSent = await upload("Tag_B")

        #expect(!firstAnswered)
        #expect(!secondSent)
        #expect(held.modifyStarted == 1)
    }

    @Test("While iCloud is taken away no operation reaches CloudKit, the account read included")
    func nothingReachesCloudKitWhileOff() async {
        allowed.withLock { $0 = false }
        let zone = CKRecordZone.ID(zoneName: CloudKitSyncEngine.zoneName, ownerName: "_alice")

        await #expect(throws: CancellationError.self) { _ = try await database.accountStatus() }
        await #expect(throws: CancellationError.self) { _ = try await database.userRecordName() }
        await #expect(throws: CancellationError.self) { _ = try await database.fetchChanges(in: zone, since: nil) }
        await #expect(throws: CancellationError.self) { try await database.deleteZone(zone) }
        await #expect(throws: CancellationError.self) { try await database.saveSubscription(SyncPushSubscription.make()) }
        _ = await upload("Tag_A")

        #expect(held.operations == 0)
    }

    @Test("While iCloud is allowed every operation goes through")
    func allowedOperationsGoThrough() async throws {
        #expect(try await database.accountStatus() == .available)
        #expect(await upload("Tag_A"))
        #expect(held.modifyStarted == 1)
    }
}
