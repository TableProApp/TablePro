import CloudKit
import Foundation
import Testing

import TableProSyncTransport

@Suite("Sync metadata storage")
struct SyncMetadataStorageTests {
    private func makeStorage() -> SyncMetadataStorage {
        let defaults = ScratchDefaults.make() ?? .standard
        return SyncMetadataStorage(userDefaults: defaults)
    }

    @Test("A dirty identifier is recorded and read back")
    func dirtyRoundTrips() {
        let storage = makeStorage()
        storage.markDirty("a", type: .connection)
        #expect(storage.dirtyIds(for: .connection) == ["a"])
    }

    @Test("Dirty sets are kept per record type")
    func dirtySetsAreIsolatedPerType() {
        let storage = makeStorage()
        storage.markDirty("a", type: .connection)
        storage.markDirty("b", type: .group)
        #expect(storage.dirtyIds(for: .connection) == ["a"])
        #expect(storage.dirtyIds(for: .group) == ["b"])
    }

    @Test("Removing the last dirty identifier empties the set")
    func removingLastDirtyEmptiesTheSet() {
        let storage = makeStorage()
        storage.markDirty("a", type: .connection)
        storage.removeDirty("a", type: .connection)
        #expect(storage.dirtyIds(for: .connection).isEmpty)
    }

    @Test("A build that reads a record type the last one did not reports the set as grown")
    func readableRecordTypesReportGrowth() {
        let storage = makeStorage()
        #expect(storage.adoptReadableRecordTypes(["Connection"]))
        #expect(!storage.adoptReadableRecordTypes(["Connection"]))
        #expect(storage.adoptReadableRecordTypes(["Connection", "TableFolder"]))
        #expect(!storage.adoptReadableRecordTypes(["Connection"]))
        #expect(storage.adoptReadableRecordTypes(["Connection", "TableFolder"]))
    }

    @Test("Removing tombstones in a batch keeps the others")
    func removeTombstonesKeepsOthers() {
        let storage = makeStorage()
        storage.addTombstones(["a", "b", "c"], type: .tableFolder)
        storage.removeTombstones(["a", "c", "missing"], type: .tableFolder)
        #expect(storage.tombstones(for: .tableFolder).map(\.id) == ["b"])
    }

    @Test("Clearing dirty removes every identifier for the type")
    func clearDirtyRemovesEverything() {
        let storage = makeStorage()
        storage.markDirty("a", type: .connection)
        storage.markDirty("b", type: .connection)
        storage.clearDirty(type: .connection)
        #expect(storage.dirtyIds(for: .connection).isEmpty)
    }

    @Test("A tombstone is recorded and read back")
    func tombstoneRoundTrips() {
        let storage = makeStorage()
        storage.addTombstone("a", type: .connection)
        #expect(storage.tombstones(for: .connection).map(\.id) == ["a"])
    }

    @Test("A removed tombstone is gone")
    func removedTombstoneIsGone() {
        let storage = makeStorage()
        storage.addTombstone("a", type: .connection)
        storage.removeTombstone("a", type: .connection)
        #expect(storage.tombstones(for: .connection).isEmpty)
    }

    @Test("Pruning drops tombstones older than the cutoff and keeps newer ones")
    func pruningDropsOldTombstonesOnly() throws {
        let defaults = ScratchDefaults.make() ?? .standard
        let old = Tombstone(id: "old", deletedAt: Date(timeIntervalSinceNow: -60 * 60 * 24 * 40))
        let fresh = Tombstone(id: "fresh", deletedAt: Date())
        let data = try JSONEncoder().encode([old, fresh])
        defaults.set(data, forKey: "com.TablePro.sync.tombstones.\(SyncRecordType.connection.rawValue)")

        let storage = SyncMetadataStorage(userDefaults: defaults)
        storage.pruneTombstones(olderThan: 30) { _, _ in true }

        #expect(storage.tombstones(for: .connection).map(\.id) == ["fresh"])
    }

    @Test("Pruning keeps an old tombstone that cannot be pushed yet")
    func pruningKeepsUnpushableTombstones() throws {
        let defaults = ScratchDefaults.make() ?? .standard
        let heldOwner = UUID()
        let fortyDaysAgo = Date(timeIntervalSinceNow: -60 * 60 * 24 * 40)
        let held = Tombstone(id: "held", deletedAt: fortyDaysAgo, owner: heldOwner)
        let released = Tombstone(id: "released", deletedAt: fortyDaysAgo, owner: UUID())
        let data = try JSONEncoder().encode([held, released])
        defaults.set(data, forKey: "com.TablePro.sync.tombstones.\(SyncRecordType.tableFavorite.rawValue)")

        let storage = SyncMetadataStorage(userDefaults: defaults)
        storage.pruneTombstones(olderThan: 30) { _, tombstone in tombstone.owner != heldOwner }

        #expect(storage.tombstones(for: .tableFavorite).map(\.id) == ["held"])
    }

    @Test("A tombstone keeps the owner it was recorded with")
    func tombstoneOwnerRoundTrips() {
        let storage = makeStorage()
        let owner = UUID()
        storage.addTombstones(["a", "b"], type: .tableFavorite, owner: owner)
        storage.addTombstone("c", type: .tableFavorite)

        #expect(storage.tombstones(for: .tableFavorite).map(\.owner) == [owner, owner, nil])
    }

    @Test("A tombstone written before owners existed still decodes, with no owner")
    func legacyTombstoneDecodesWithoutOwner() throws {
        let defaults = ScratchDefaults.make() ?? .standard
        let legacy = Data(#"[{"id":"a","deletedAt":780000000}]"#.utf8)
        defaults.set(legacy, forKey: "com.TablePro.sync.tombstones.\(SyncRecordType.favoriteDatabase.rawValue)")

        let tombstones = SyncMetadataStorage(userDefaults: defaults).tombstones(for: .favoriteDatabase)

        #expect(tombstones.map(\.id) == ["a"])
        #expect(tombstones.map(\.owner) == [nil])
    }

    @Test("Owners kept off sync survive a new storage instance and can be released one by one")
    func ownersKeptOffSyncPersist() {
        let defaults = ScratchDefaults.make() ?? .standard
        let first = UUID()
        let second = UUID()
        SyncMetadataStorage(userDefaults: defaults).keepOffSync(owners: [first, second])

        let storage = SyncMetadataStorage(userDefaults: defaults)
        #expect(storage.ownersKeptOffSync() == [first, second])

        storage.releaseOwnersKeptOffSync([first])
        #expect(storage.ownersKeptOffSync() == [second])
        storage.clearAll()
        #expect(storage.ownersKeptOffSync() == [second])
    }

    @Test("Removing tombstones by a predicate reaches every type and leaves the rest")
    func removingOwnedTombstonesKeepsTheRest() {
        let storage = makeStorage()
        let removed = UUID()
        let kept = UUID()
        storage.addTombstones(["a"], type: .tableFavorite, owner: removed)
        storage.addTombstones(["b"], type: .favorite, owner: removed)
        storage.addTombstones(["c"], type: .tableFavorite, owner: kept)
        storage.addTombstone("d", type: .tag)

        storage.removeTombstones { _, tombstone in tombstone.owner == removed }

        #expect(storage.tombstones(for: .tableFavorite).map(\.id) == ["c"])
        #expect(storage.tombstones(for: .favorite).isEmpty)
        #expect(storage.tombstones(for: .tag).map(\.id) == ["d"])
    }

    @Test("The last sync date round-trips")
    func lastSyncDateRoundTrips() {
        let storage = makeStorage()
        #expect(storage.lastSyncDate == nil)
        let now = Date()
        storage.lastSyncDate = now
        #expect(storage.lastSyncDate?.timeIntervalSince1970 == now.timeIntervalSince1970)
    }

    @Test("The last account identifier round-trips")
    func lastAccountIdRoundTrips() {
        let storage = makeStorage()
        #expect(storage.lastAccountId == nil)
        storage.lastAccountId = "account"
        #expect(storage.lastAccountId == "account")
    }

    @Test("The subscribed account round-trips and a full reset forgets it")
    func subscribedAccountIdRoundTrips() {
        let storage = makeStorage()
        #expect(storage.subscribedAccountId == nil)
        storage.subscribedAccountId = "account"
        #expect(storage.subscribedAccountId == "account")
        storage.clearAll()
        #expect(storage.subscribedAccountId == nil)
    }

    @Test("The first account seen on a device that never synced is recorded and nothing queued is dropped")
    func firstAccountIsRecorded() {
        let defaults = ScratchDefaults.make() ?? .standard
        let storage = SyncMetadataStorage(userDefaults: defaults)
        storage.markDirty("a", type: .connection)
        storage.addTombstone("b", type: .connection)

        #expect(storage.adoptAccount("account-a") == .firstSeen)

        #expect(storage.lastAccountId == "account-a")
        #expect(storage.dirtyIds(for: .connection) == ["a"])
        #expect(storage.tombstones(for: .connection).map(\.id) == ["b"])
    }

    @Test("An account recorded for the first time over an earlier sync starts sync over once and keeps what is queued")
    func unrecordedEarlierSyncStartsOverOnce() {
        let defaults = ScratchDefaults.make() ?? .standard
        let storage = SyncMetadataStorage(userDefaults: defaults)
        storage.markDirty("a", type: .connection)
        storage.addTombstone("b", type: .connection)
        storage.lastSyncDate = Date()
        defaults.set(Data([1, 2, 3]), forKey: "com.TablePro.sync.serverChangeToken")

        #expect(storage.adoptAccount("account-a") == .previousAccountUnknown)

        #expect(storage.lastAccountId == "account-a")
        #expect(defaults.data(forKey: "com.TablePro.sync.serverChangeToken") == nil)
        #expect(storage.lastSyncDate == nil)
        #expect(storage.dirtyIds(for: .connection) == ["a"])
        #expect(storage.tombstones(for: .connection).map(\.id) == ["b"])

        defaults.set(Data([4, 5, 6]), forKey: "com.TablePro.sync.serverChangeToken")
        #expect(storage.adoptAccount("account-a") == .unchanged)
        #expect(defaults.data(forKey: "com.TablePro.sync.serverChangeToken") == Data([4, 5, 6]))
    }

    @Test("The same account changes nothing")
    func sameAccountChangesNothing() {
        let defaults = ScratchDefaults.make() ?? .standard
        let storage = SyncMetadataStorage(userDefaults: defaults)
        storage.lastAccountId = "account-a"
        storage.markDirty("a", type: .connection)
        storage.lastSyncDate = Date()
        defaults.set(Data([1, 2, 3]), forKey: "com.TablePro.sync.serverChangeToken")

        #expect(storage.adoptAccount("account-a") == .unchanged)

        #expect(storage.dirtyIds(for: .connection) == ["a"])
        #expect(storage.lastSyncDate != nil)
        #expect(defaults.data(forKey: "com.TablePro.sync.serverChangeToken") == Data([1, 2, 3]))
    }

    @Test("A different account clears the old account's token and deletions, and keeps edits waiting to go up")
    func differentAccountStartsOver() {
        let defaults = ScratchDefaults.make() ?? .standard
        let storage = SyncMetadataStorage(userDefaults: defaults)
        storage.lastAccountId = "account-a"
        storage.markDirty("a", type: .connection)
        storage.markDirty("c", type: .tag)
        storage.addTombstone("b", type: .group)
        storage.lastSyncDate = Date()
        defaults.set(Data([1, 2, 3]), forKey: "com.TablePro.sync.serverChangeToken")

        #expect(storage.adoptAccount("account-b") == .switched)

        #expect(storage.lastAccountId == "account-b")
        #expect(storage.dirtyIds(for: .connection) == ["a"])
        #expect(storage.dirtyIds(for: .tag) == ["c"])
        #expect(storage.tombstones(for: .group).isEmpty)
        #expect(storage.lastSyncDate == nil)
        #expect(defaults.data(forKey: "com.TablePro.sync.serverChangeToken") == nil)
    }

    @Test("An absent token reads as nil")
    func absentTokenReadsAsNil() {
        #expect(makeStorage().loadToken() == nil)
    }

    @Test("Saving a nil token clears the stored one")
    func savingNilClearsTheToken() {
        let storage = makeStorage()
        storage.saveToken(nil)
        #expect(storage.loadToken() == nil)
    }

    @Test("Clearing everything resets every kind of metadata")
    func clearAllResetsEverything() {
        let storage = makeStorage()
        storage.markDirty("a", type: .connection)
        storage.addTombstone("b", type: .group)
        storage.lastSyncDate = Date()
        storage.lastAccountId = "account"

        storage.clearAll()

        #expect(storage.dirtyIds(for: .connection).isEmpty)
        #expect(storage.tombstones(for: .group).isEmpty)
        #expect(storage.lastSyncDate == nil)
        #expect(storage.lastAccountId == nil)
    }

    @Test("Storage keys are the ones already on disk")
    func storageKeysAreStable() {
        let defaults = ScratchDefaults.make() ?? .standard
        let storage = SyncMetadataStorage(userDefaults: defaults)
        storage.markDirty("a", type: .connection)
        storage.addTombstone("b", type: .connection)
        storage.lastAccountId = "account"

        #expect(defaults.stringArray(forKey: "com.TablePro.sync.dirty.Connection") == ["a"])
        #expect(defaults.data(forKey: "com.TablePro.sync.tombstones.Connection") != nil)
        #expect(defaults.string(forKey: "com.TablePro.sync.lastAccountId") == "account")
    }

    // MARK: - Copies this device cannot read

    @Test("A connection's standing follows the last read of it, is kept while it cannot be read, and goes with it")
    func connectionStandingFollowsReads() throws {
        let storage = makeStorage()
        let synced = UUID()
        let localOnly = UUID()
        let never = UUID()
        storage.recordConnectionStanding(syncing: [synced], keptOff: [localOnly], unreadable: [])

        storage.recordConnectionStanding(syncing: [], keptOff: [], unreadable: [synced, localOnly, never])

        #expect(storage.standing(ofConnection: synced) == .syncs)
        #expect(storage.standing(ofConnection: localOnly) == .keptOff)
        #expect(storage.standing(ofConnection: never) == .unknown)

        storage.recordConnectionStanding(syncing: [], keptOff: [], unreadable: [])
        #expect(storage.standing(ofConnection: synced) == .unknown)
        #expect(storage.standing(ofConnection: localOnly) == .unknown)
    }

    @Test("A deletion removes an unread copy that syncs, leaves a Local only one, and holds one with no standing")
    func deletionOfUnreadCopiesFollowsStanding() {
        let storage = makeStorage()
        let synced = UUID()
        let localOnly = UUID()
        let unknown = UUID()
        storage.recordConnectionStanding(syncing: [synced], keptOff: [localOnly], unreadable: [])

        let removed = storage.unreadableConnectionsRemoved(byDeletionOf: [synced, localOnly, unknown])

        #expect(removed == [synced])
        #expect(storage.deletionsHeldForUnreadableCopies == [SyncRecordType.connection.recordName(for: unknown.uuidString)])
    }

    @Test("A held change is fetched once its copy reads, and dropped once its copy is gone or no longer syncs")
    func heldChangesWaitForAReadableCopy() {
        let storage = makeStorage()
        storage.changesHeldForUnreadableCopies = ["Connection_A", "Connection_B", "Connection_C"]

        let readable = storage.readableHeldChanges(syncing: ["Connection_A", "Connection_B"], unreadable: ["Connection_B"])

        #expect(readable == ["Connection_A"])
        #expect(storage.changesHeldForUnreadableCopies == ["Connection_A", "Connection_B"])
    }

    @Test("Records held for unread copies belong to the account that sent them, so switching accounts drops them")
    func heldRecordsGoWithTheAccount() {
        let storage = makeStorage()
        _ = storage.adoptAccount("first")
        storage.changesHeldForUnreadableCopies = ["Connection_A"]
        storage.deletionsHeldForUnreadableCopies = ["Connection_B"]

        _ = storage.adoptAccount("second")

        #expect(storage.changesHeldForUnreadableCopies.isEmpty)
        #expect(storage.deletionsHeldForUnreadableCopies.isEmpty)
    }

    @Test("A held deletion falls due once its copy reads, and settles unapplied when the server sent the record again")
    func heldDeletionsFallDueWhenReadable() {
        let storage = makeStorage()
        storage.deletionsHeldForUnreadableCopies = ["Connection_A", "Connection_B", "Connection_C"]

        let held = storage.heldDeletions(live: ["Connection_C"], unreadable: ["Connection_B"])

        #expect(held.due == ["Connection_A"])
        #expect(held.settled == ["Connection_A", "Connection_C"])
    }
}
