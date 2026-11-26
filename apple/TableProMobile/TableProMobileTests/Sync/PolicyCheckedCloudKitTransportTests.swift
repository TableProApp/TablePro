import CloudKit
import Foundation
import os
import TableProFFI
@testable import TableProMobile
import TableProSyncTransport
import TableProTestSupport
import Testing

// P1-I3: an upload in flight stops sending batches once the organization turns iCloud off, checked per batch.
struct PolicyCheckedCloudKitTransportTests {
    private let database = HeldCloudKitDatabase()
    private let base: CloudKitCoreTransport
    private let allowed = OSAllocatedUnfairLock(initialState: true)
    private let transport: PolicyCheckedCloudKitTransport

    init() {
        base = CloudKitCoreTransport(database: database)
        base.open()
        transport = PolicyCheckedCloudKitTransport(base: base) { [allowed] in allowed.withLock { $0 } }
    }

    private static func tag(_ name: String) -> CloudKitRecord {
        CloudKitRecord(recordType: "ConnectionTag", name: name, systemFields: nil, createdMs: nil, fields: [])
    }

    @Test("A batch that starts after iCloud was taken away reaches no CloudKit operation, and closes the transport")
    func aLaterBatchIsRefused() async throws {
        database.holdNextModify()
        let first = Task { try await transport.modify(account: "_alice", saves: [Self.tag("Tag_A")], deletes: []) }
        try await waitUntil { database.modifyStarted == 1 }

        allowed.withLock { $0 = false }
        database.releaseHeldModify()
        let sent = try await first.value
        await #expect(throws: CloudKitFailure.Other(code: Int64(CKError.Code.operationCancelled.rawValue))) {
            _ = try await transport.modify(account: "_alice", saves: [Self.tag("Tag_B")], deletes: [])
        }

        #expect(sent.count == 1)
        #expect(database.modifyStarted == 1)
        #expect(base.isClosed)
    }

    @Test("While iCloud is allowed every call goes through")
    func allowedCallsGoThrough() async throws {
        let outcomes = try await transport.modify(account: "_alice", saves: [Self.tag("Tag_A")], deletes: [])

        #expect(outcomes.count == 1)
        #expect(!base.isClosed)
    }
}
