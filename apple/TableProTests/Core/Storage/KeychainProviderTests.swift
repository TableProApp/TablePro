import Foundation
import Security
@testable import TablePro
import Testing

private final class ProviderStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state: KeychainProviderState

    init(_ state: KeychainProviderState) {
        self.state = state
    }

    var value: KeychainProviderState {
        get { lock.withLock { state } }
        set { lock.withLock { state = newValue } }
    }
}

struct KeychainProviderTests {
    private let store = ScopedKeychainItemStore()
    private let key = "com.TablePro.password.provider"
    private let provider = ProviderStateBox(.followsPasswordSync)

    private func helper(passwordSync: Bool = false, followsPasswordSync: Bool = true) -> KeychainHelper {
        KeychainHelper(
            service: "com.TablePro.tests.provider",
            followsPasswordSync: followsPasswordSync,
            passwordSyncSetting: { passwordSync },
            providerState: { [provider] in provider.value },
            items: store
        )
    }

    private func onTableProSync(copiesAdded: Bool) {
        provider.value = KeychainProviderState(onTableProSync: true, deviceCopiesAdded: copiesAdded)
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
        provider.value = .followsPasswordSync

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

    @Test("The provider state round-trips through defaults, and leaving TablePro Sync clears it")
    func providerStateRoundTrips() throws {
        let suite = try EphemeralDefaults()
        let state = KeychainProviderState(onTableProSync: true, deviceCopiesAdded: true)

        state.store(in: suite.defaults)
        #expect(KeychainProviderState.stored(in: suite.defaults) == state)

        KeychainProviderState.followsPasswordSync.store(in: suite.defaults)
        #expect(KeychainProviderState.stored(in: suite.defaults) == .followsPasswordSync)
        #expect(suite.defaults.object(forKey: KeychainProviderState.providerKey) == nil)
    }
}
