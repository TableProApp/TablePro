import Foundation
import Security
@testable import TablePro
import Testing

struct KeychainProviderTests {
    private let store = ScopedKeychainItemStore()
    private let key = "com.TablePro.password.provider"
    private let suite: EphemeralDefaults
    private let record: DefaultsKeychainProviderRecord

    init() throws {
        let suite = try EphemeralDefaults()
        self.suite = suite
        record = DefaultsKeychainProviderRecord { [defaults = suite.defaults] in defaults }
    }

    private func helper(passwordSync: Bool = false, followsPasswordSync: Bool = true) -> KeychainHelper {
        KeychainHelper(
            service: "com.TablePro.tests.provider",
            followsPasswordSync: followsPasswordSync,
            passwordSyncSetting: { passwordSync },
            provider: record,
            items: store
        )
    }

    private func onTableProSync(copiesAdded: Bool) {
        record.store(KeychainProviderState(onTableProSync: true, deviceCopiesAdded: copiesAdded))
    }

    @Test("On TablePro Sync a save goes to this Mac's own item and the iCloud item stays, even with password sync on")
    func saveStaysOnThisMac() {
        store.seed("synced", account: key, synchronizable: true)
        onTableProSync(copiesAdded: true)

        #expect(helper(passwordSync: true).writeString("new", forKey: key))

        #expect(store.value(account: key, synchronizable: false) == "new")
        #expect(store.value(account: key, synchronizable: true) == "synced")
    }

    @Test("On TablePro Sync this Mac's own item is read over a newer iCloud one")
    func readPrefersThisMacsItem() {
        store.seed("local", account: key, synchronizable: false)
        store.seed("newer-synced", account: key, synchronizable: true)
        onTableProSync(copiesAdded: true)

        #expect(helper(passwordSync: true).readString(forKey: key) == "local")
    }

    @Test("On TablePro Sync a delete removes this Mac's item only, and the iCloud copy never brings it back")
    func deleteKeepsTheICloudItemAndStaysDeleted() {
        store.seed("local", account: key, synchronizable: false)
        store.seed("synced", account: key, synchronizable: true)
        onTableProSync(copiesAdded: true)
        let keychain = helper()

        keychain.delete(forKey: key)

        #expect(store.value(account: key, synchronizable: false) == nil)
        #expect(store.value(account: key, synchronizable: true) == "synced")
        #expect(keychain.readStringResult(forKey: key) == .notFound)
        #expect(keychain.readStringResult(forKey: key, deviceOnly: true) == .notFound)
    }

    @Test("Until every iCloud item has a copy here, a secret only iCloud Keychain holds is still read")
    func readFallsBackUntilTheCopiesAreAdded() {
        store.seed("synced", account: key, synchronizable: true)
        onTableProSync(copiesAdded: false)

        #expect(helper().readString(forKey: key) == "synced")
    }

    @Test("On TablePro Sync removing the iCloud copy of a Local only secret leaves it for the devices on iCloud")
    func removingTheSyncedCopyIsANoOp() {
        store.seed("local", account: key, synchronizable: false)
        store.seed("synced", account: key, synchronizable: true)
        onTableProSync(copiesAdded: true)

        #expect(helper().removeSyncedCopy(forKey: key))

        #expect(store.value(account: key, synchronizable: true) == "synced")
    }

    @Test("Back on iCloud, password sync decides again and the iCloud item is read")
    func backOnICloudFollowsPasswordSync() {
        store.seed("synced", account: key, synchronizable: true)
        record.store(.followsPasswordSync)

        #expect(helper(passwordSync: true).readString(forKey: key) == "synced")
        #expect(helper(passwordSync: true).writeString("new", forKey: key))
        #expect(store.value(account: key, synchronizable: true) == "new")
    }

    @Test("A credential bound to this Mac reads and deletes as before on TablePro Sync")
    func boundCredentialIsUnchanged() {
        store.seed("synced", account: key, synchronizable: true)
        onTableProSync(copiesAdded: true)
        let bound = helper(followsPasswordSync: false)

        #expect(bound.readString(forKey: key) == "synced")
    }

    @Test("Copies give each iCloud item an item of this Mac's own with its value, and keep the iCloud item")
    func copiesAddDeviceOnlyItems() {
        store.seed("synced-a", account: "a", synchronizable: true)
        store.seed("synced-b", account: "b", synchronizable: true)
        store.seed("own-b", account: "b", synchronizable: false)

        #expect(helper().addDeviceOnlyCopies())

        #expect(store.value(account: "a", synchronizable: false) == "synced-a")
        #expect(store.value(account: "a", synchronizable: true) == "synced-a")
        #expect(store.value(account: "b", synchronizable: false) == "own-b")
        #expect(store.value(account: "b", synchronizable: true) == "synced-b")
    }

    @Test("After the copies, a build that knows no TablePro Sync reads the same secrets, iCloud off as the move left it")
    func previousStableReadsTheCopies() {
        store.seed("synced", account: key, synchronizable: true)
        #expect(helper().addDeviceOnlyCopies())
        onTableProSync(copiesAdded: true)
        #expect(helper().writeString("edited-on-tablepro-sync", forKey: key))

        record.store(.followsPasswordSync)

        #expect(helper(passwordSync: false).readString(forKey: key) == "edited-on-tablepro-sync")
        #expect(store.value(account: key, synchronizable: true) == "synced")
    }

    @Test("A locked item or a locked listing leaves the copies unfinished, and the rest still get theirs")
    func lockedItemsLeaveCopiesUnfinished() {
        store.seed("synced-a", account: "a", synchronizable: true)
        store.seed("synced-b", account: "b", synchronizable: true)
        store.lockItems(of: "a")

        #expect(!helper().addDeviceOnlyCopies())
        #expect(store.value(account: "b", synchronizable: false) == "synced-b")

        store.unlockItems(of: "a")
        store.lockListing(true)

        #expect(!helper().addDeviceOnlyCopies())

        store.lockListing(false)

        #expect(helper().addDeviceOnlyCopies())
        #expect(store.value(account: "a", synchronizable: false) == "synced-a")
    }

    @Test("Before every copy is made, a secret removed here is neither read back from iCloud nor copied back")
    func removalBeforeTheCopiesStays() {
        store.seed("synced-a", account: "a", synchronizable: true)
        store.seed("synced-b", account: "b", synchronizable: true)
        store.lockItems(of: "b")
        onTableProSync(copiesAdded: false)
        let keychain = helper()
        #expect(!keychain.addDeviceOnlyCopies())

        keychain.delete(forKey: "a")
        store.unlockItems(of: "b")

        #expect(keychain.readStringResult(forKey: "a") == .notFound)
        #expect(keychain.addDeviceOnlyCopies())
        #expect(store.value(account: "a", synchronizable: false) == nil)
        #expect(store.value(account: "a", synchronizable: true) == "synced-a")
        #expect(store.value(account: "b", synchronizable: false) == "synced-b")
    }

    @Test("A secret saved again after its removal is read again")
    func savedAgainAfterRemoval() {
        store.seed("synced", account: key, synchronizable: true)
        onTableProSync(copiesAdded: false)
        let keychain = helper()

        keychain.delete(forKey: key)
        #expect(keychain.writeString("new", forKey: key))

        #expect(!record.isRemovedHere(key))
        #expect(keychain.readString(forKey: key) == "new")
    }

    @Test("The state round-trips through defaults, and finishing the copies or leaving TablePro Sync ends the removals")
    func stateRoundTripsAndRemovalsEnd() {
        let state = KeychainProviderState(onTableProSync: true, deviceCopiesAdded: false)
        record.store(state)
        record.noteRemovedHere(key)
        #expect(record.state == state)
        #expect(record.isRemovedHere(key))

        record.store(KeychainProviderState(onTableProSync: true, deviceCopiesAdded: true))
        #expect(!record.isRemovedHere(key))

        record.noteRemovedHere(key)
        record.store(.followsPasswordSync)

        #expect(record.state == .followsPasswordSync)
        #expect(!record.isRemovedHere(key))
        #expect(suite.defaults.object(forKey: DefaultsKeychainProviderRecord.providerKey) == nil)
    }
}
