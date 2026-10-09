import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

/// How a run ends when CloudKit refuses it, per item or as a whole. The status and Last Synced are
/// settled by `SyncSettlement`, whose own suite covers them; these cover what a run sends, keeps and
/// reports.
@MainActor
struct SyncCoordinatorFailureTests {
    private static let zoneID = SyncTestEnvironment.zoneID

    private let environment: SyncTestEnvironment
    private let metadata: SyncMetadataStorage
    private let tracker: SyncChangeTracker
    private let tags: TagStorage

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-failure")
        metadata = environment.metadata
        tracker = environment.tracker
        tags = environment.tags
    }

    private func makeTransport() -> ScriptedSyncTransport {
        ScriptedSyncTransport(zoneID: Self.zoneID)
    }

    /// The reported bug: every save and delete came back `quotaExceeded`, and the person was shown
    /// the first item's raw text with its CKRecordID.
    @Test("Full storage on every item is reported as full storage, with every change kept")
    func storageFullKeepsEverything() async throws {
        let kept = ConnectionTag(name: "staging")
        let removed = ConnectionTag(name: "scratch")
        try tags.addTag(kept)
        try tags.addTag(removed)
        tags.deleteTag(removed)
        let transport = makeTransport()
        await transport.failEveryItem(with: .quotaExceeded, retryAfter: 316)

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == .blocked(.storageFull))
        #expect(tracker.dirtyRecords(for: .tag).contains(kept.id.uuidString))
        #expect(metadata.tombstones(for: .tag).map(\.id).contains(removed.id.uuidString))
        #expect(metadata.lastSyncDate == nil)
    }

    @Test("A download-only run sends nothing and still pulls")
    func downloadOnlySendsNothing() async throws {
        try tags.addTag(ConnectionTag(name: "staging"))
        let transport = makeTransport()

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle(.downloadOnly)

        #expect(failure == nil)
        #expect(await transport.pushCount == 0)
        #expect(await transport.pullCount == 1)
        #expect(!tracker.dirtyRecords(for: .tag).isEmpty)
    }

    /// A failed pull used to be logged and dropped, so the run said Synced while other devices'
    /// changes never arrived.
    @Test("A failed download fails the run")
    func failedPullFailsTheRun() async throws {
        let transport = makeTransport()
        await transport.failPulls(with: CKError(.networkFailure))

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == .offline)
    }

    @Test("A restricted account is reported as restricted, and nothing is sent or fetched")
    func restrictedAccount() async throws {
        try tags.addTag(ConnectionTag(name: "staging"))
        let transport = makeTransport()
        await transport.setAccountStatus(.restricted)

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == .blocked(.accountRestricted))
        #expect(await transport.pushCount == 0)
        #expect(await transport.pullCount == 0)
    }

    @Test("An account that cannot be read yet is not ready, never signed out")
    func undeterminedAccount() async throws {
        let transport = makeTransport()
        await transport.setAccountStatus(.couldNotDetermine)

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == .blocked(.accountNotReady))
    }

    /// CloudKit sends `notAuthenticated` for every account state that is not available, so the
    /// account is read again before the person is told to sign in.
    @Test("A not-authenticated item on an available account means the account is not ready")
    func notAuthenticatedWhileAvailable() async throws {
        try tags.addTag(ConnectionTag(name: "staging"))
        let transport = makeTransport()
        await transport.failEveryItem(with: .notAuthenticated)

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == .blocked(.accountNotReady))
    }

    /// The account id was written before it was compared, so a switch was never noticed and the
    /// old account's token was sent to the new one.
    @Test("Another iCloud account starts the server side over")
    func accountSwitchForgetsTheServerPosition() async throws {
        let transport = makeTransport()
        let coordinator = environment.makeCoordinator(transport: transport)
        #expect(await coordinator.runSyncCycle() == nil)
        metadata.lastSyncDate = Date(timeIntervalSince1970: 1_000)
        await transport.setAccountId("someone-else")

        #expect(await coordinator.runSyncCycle() == nil)

        #expect(metadata.lastAccountId == "someone-else")
        #expect(metadata.lastSyncDate == nil)
    }

    @Test("The zone is saved once, not on every run")
    func zoneIsSavedOnce() async throws {
        let transport = makeTransport()
        let coordinator = environment.makeCoordinator(transport: transport)

        #expect(await coordinator.runSyncCycle() == nil)
        #expect(await coordinator.runSyncCycle() == nil)

        #expect(await transport.zoneSaveCount == 1)
        #expect(metadata.zoneState == .confirmed)
    }

    /// Apple asks apps not to resend data the person removed from iCloud, so a missing zone waits
    /// for the person instead of being recreated and refilled behind their back.
    @Test("A zone that is gone waits for the person and is not recreated by a download")
    func missingZoneWaitsForThePerson() async throws {
        try tags.addTag(ConnectionTag(name: "staging"))
        let transport = makeTransport()
        let coordinator = environment.makeCoordinator(transport: transport)
        #expect(await coordinator.runSyncCycle() == nil)
        try tags.addTag(ConnectionTag(name: "qa"))
        await transport.failEveryItem(with: .zoneNotFound)

        let failure = await coordinator.runSyncCycle()

        #expect(failure == .blocked(.dataDeletedFromICloud))
        #expect(metadata.zoneState == .removed)
        #expect(await coordinator.runSyncCycle(.downloadOnly) == nil)
        #expect(await transport.zoneSaveCount == 1)
    }

    /// The block used to live only in memory, so the first run after a relaunch saved the zone
    /// again and uploaded into it.
    @Test("A zone known to be removed is never recreated by a run, even one admitted in full")
    func removedZoneIsNotRecreated() async throws {
        try tags.addTag(ConnectionTag(name: "staging"))
        metadata.zoneState = .removed
        let transport = makeTransport()
        await transport.failEveryItem(with: .zoneNotFound)

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == .blocked(.dataDeletedFromICloud))
        #expect(await transport.zoneSaveCount == 0)
        #expect(metadata.zoneState == .removed)
    }

    /// A new Mac whose first zone save failed on full storage has a zone to wait for, not one the
    /// person deleted.
    @Test("A download that finds no zone this Mac never saw is not a deletion")
    func unseenZoneIsNotRemoved() async throws {
        let transport = makeTransport()
        await transport.failPulls(with: CKError(.zoneNotFound))

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle(.downloadOnly)

        #expect(failure == nil)
        #expect(metadata.zoneState == .unknown)
    }

    @Test("A deleted zone reported by the download is the same blocker")
    func deletedZoneOnPull() async throws {
        let transport = makeTransport()
        await transport.failPulls(with: CKError(.userDeletedZone))

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == .blocked(.dataDeletedFromICloud))
        #expect(metadata.zoneState == .removed)
    }

    @Test("Items refused one by one are counted, not shown as CloudKit text")
    func rejectedItemsAreCounted() async throws {
        let tag = ConnectionTag(name: "staging")
        try tags.addTag(tag)
        let recordID = SyncRecordMapper.toCKRecord(tag, in: Self.zoneID).recordID
        let transport = ScriptedSyncTransport(zoneID: Self.zoneID, rejecting: [recordID])

        let failure = await environment.makeCoordinator(transport: transport).runSyncCycle()

        #expect(failure == .recordsRejected(count: 1))
    }
}
