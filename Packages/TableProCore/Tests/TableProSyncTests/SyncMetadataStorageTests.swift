import CloudKit
import Foundation
import Testing

import TableProSyncTransport

@Suite("Sync metadata storage")
struct SyncMetadataStorageTests {
    private func makeStorage() -> SyncMetadataStorage {
        let defaults = UserDefaults(suiteName: "com.TablePro.tests.\(UUID().uuidString)") ?? .standard
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
        let defaults = UserDefaults(suiteName: "com.TablePro.tests.\(UUID().uuidString)") ?? .standard
        let old = Tombstone(id: "old", deletedAt: Date(timeIntervalSinceNow: -60 * 60 * 24 * 40))
        let fresh = Tombstone(id: "fresh", deletedAt: Date())
        let data = try JSONEncoder().encode([old, fresh])
        defaults.set(data, forKey: "com.TablePro.sync.tombstones.\(SyncRecordType.connection.rawValue)")

        let storage = SyncMetadataStorage(userDefaults: defaults)
        storage.pruneTombstones(olderThan: 30)

        #expect(storage.tombstones(for: .connection).map(\.id) == ["fresh"])
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
        let defaults = UserDefaults(suiteName: "com.TablePro.tests.\(UUID().uuidString)") ?? .standard
        let storage = SyncMetadataStorage(userDefaults: defaults)
        storage.markDirty("a", type: .connection)
        storage.addTombstone("b", type: .connection)
        storage.lastAccountId = "account"

        #expect(defaults.stringArray(forKey: "com.TablePro.sync.dirty.Connection") == ["a"])
        #expect(defaults.data(forKey: "com.TablePro.sync.tombstones.Connection") != nil)
        #expect(defaults.string(forKey: "com.TablePro.sync.lastAccountId") == "account")
    }
}
