import Foundation
import Security
@testable import TablePro
import Testing

struct KeychainItemScopeTests {
    private let store = ScopedKeychainItemStore()
    private let key = "com.TablePro.password.scope"

    private func helper(passwordSync: Bool, followsPasswordSync: Bool = true) -> KeychainHelper {
        KeychainHelper(
            service: "com.TablePro.tests.scope",
            followsPasswordSync: followsPasswordSync,
            passwordSyncSetting: { passwordSync },
            items: store
        )
    }

    @Test("With password sync on, a write with a synced and a local item saves the synced one and drops the local one")
    func writeWithBothItemsPresent() {
        store.seed("old-local", account: key, synchronizable: false)
        store.seed("old-synced", account: key, synchronizable: true)
        let keychain = helper(passwordSync: true)

        #expect(keychain.writeString("new", forKey: key))

        #expect(store.value(account: key, synchronizable: true) == "new")
        #expect(store.value(account: key, synchronizable: false) == nil)
        #expect(keychain.readString(forKey: key) == "new")
    }

    @Test("With password sync off, a write with both items saves the local one and leaves the synced one alone")
    func localWriteKeepsTheSyncedItem() {
        store.seed("old-local", account: key, synchronizable: false)
        store.seed("from-another-device", account: key, synchronizable: true)
        let keychain = helper(passwordSync: false)

        #expect(keychain.writeString("new", forKey: key))

        #expect(store.value(account: key, synchronizable: false) == "new")
        #expect(store.value(account: key, synchronizable: true) == "from-another-device")
        #expect(keychain.readString(forKey: key) == "new")
    }

    @Test("With password sync off, saving a secret another device synced never deletes that device's item")
    func localWriteNeverDeletesASyncedItem() {
        store.seed("from-another-device", account: key, synchronizable: true)

        #expect(helper(passwordSync: false).writeString("new", forKey: key))

        #expect(store.value(account: key, synchronizable: true) == "from-another-device")
        #expect(store.value(account: key, synchronizable: false) == "new")
    }

    @Test("With password sync on, a write moves an item saved before it was on into iCloud Keychain")
    func writeMovesLocalItemToSynced() {
        store.seed("old-local", account: key, synchronizable: false)

        #expect(helper(passwordSync: true).writeString("new", forKey: key))

        #expect(store.value(account: key, synchronizable: true) == "new")
        #expect(store.value(account: key, synchronizable: false) == nil)
    }

    @Test("A device-only write stays out of iCloud Keychain and leaves the synced copy for other devices")
    func deviceOnlyWriteKeepsSyncedCopy() {
        store.seed("old-synced", account: key, synchronizable: true)
        let keychain = helper(passwordSync: true)

        #expect(keychain.writeString("new", forKey: key, deviceOnly: true))

        #expect(store.value(account: key, synchronizable: false) == "new")
        #expect(store.value(account: key, synchronizable: true) == "old-synced")
    }

    @Test("A device-only read returns this Mac's item over a synced one, whatever the setting")
    func deviceOnlyReadPrefersTheLocalItem() {
        store.seed("local", account: key, synchronizable: false)
        store.seed("synced", account: key, synchronizable: true)
        let keychain = helper(passwordSync: true)

        #expect(keychain.readStringResult(forKey: key, deviceOnly: true) == .found("local"))
        #expect(keychain.readStringResult(forKey: key) == .found("synced"))
    }

    @Test("A device-only read falls back to the synced item when this Mac has no copy yet")
    func deviceOnlyReadFallsBackToTheSyncedItem() {
        store.seed("synced", account: key, synchronizable: true)

        #expect(helper(passwordSync: false).readStringResult(forKey: key, deviceOnly: true) == .found("synced"))
    }

    @Test("A keychain that never follows password sync writes local items only")
    func deviceBoundKeychainNeverSyncs() {
        #expect(helper(passwordSync: true, followsPasswordSync: false).writeString("new", forKey: key))

        #expect(store.value(account: key, synchronizable: false) == "new")
        #expect(store.value(account: key, synchronizable: true) == nil)
    }

    @Test("With password sync on the newer item wins; with it off this Mac's own item does")
    func readReturnsTheNewerItem() {
        store.seed("synced", account: key, synchronizable: true)
        store.seed("local", account: key, synchronizable: false)

        #expect(helper(passwordSync: true).readString(forKey: key) == "local")
        #expect(helper(passwordSync: false).readString(forKey: key) == "local")

        store.seed("newer-synced", account: key, synchronizable: true)

        #expect(helper(passwordSync: true).readString(forKey: key) == "newer-synced")
        #expect(helper(passwordSync: false).readString(forKey: key) == "local")
    }

    @Test("With password sync off, a newer item another device synced never replaces this Mac's own key")
    func syncOffKeepsTheLocalItemOverANewerSyncedOne() {
        store.seed("this-mac-key", account: key, synchronizable: false)
        store.seed("other-mac-key", account: key, synchronizable: true)

        #expect(helper(passwordSync: false).readString(forKey: key) == "this-mac-key")
        #expect(helper(passwordSync: false).readStringResult(forKey: key) == .found("this-mac-key"))
    }

    @Test("A password saved with password sync off is the one read once sync is back on")
    func localSaveSurvivesTurningSyncBackOn() {
        store.seed("from-another-device", account: key, synchronizable: true)

        #expect(helper(passwordSync: false).writeString("new", forKey: key))

        #expect(helper(passwordSync: true).readString(forKey: key) == "new")
        #expect(store.value(account: key, synchronizable: true) == "from-another-device")
    }

    @Test("A credential bound to this Mac reads its own item over a newer synced one")
    func boundCredentialIgnoresANewerSyncedItem() {
        store.seed("local", account: key, synchronizable: false)
        store.seed("synced", account: key, synchronizable: true)

        #expect(helper(passwordSync: true, followsPasswordSync: false).readString(forKey: key) == "local")
        #expect(helper(passwordSync: true).readStringResult(forKey: key, deviceOnly: true) == .found("local"))
    }

    @Test("Delete removes both items")
    func deleteRemovesBothItems() {
        store.seed("local", account: key, synchronizable: false)
        store.seed("synced", account: key, synchronizable: true)
        let keychain = helper(passwordSync: false)

        keychain.delete(forKey: key)

        #expect(keychain.readStringResult(forKey: key) == .notFound)
    }

    @Test("A device-only delete removes this Mac's item and leaves the one iCloud Keychain holds", arguments: [true, false])
    func deviceOnlyDeleteKeepsTheSyncedItem(passwordSync: Bool) {
        store.seed("local", account: key, synchronizable: false)
        store.seed("synced", account: key, synchronizable: true)

        helper(passwordSync: passwordSync).delete(forKey: key, deviceOnly: true)

        #expect(store.value(account: key, synchronizable: false) == nil)
        #expect(store.value(account: key, synchronizable: true) == "synced")
    }

    @Test("Removing the synced copy keeps this Mac's own item, whatever the password sync setting", arguments: [true, false])
    func removingTheSyncedCopyKeepsTheLocalItem(passwordSync: Bool) {
        store.seed("local", account: key, synchronizable: false)
        store.seed("synced", account: key, synchronizable: true)

        #expect(helper(passwordSync: passwordSync).removeSyncedCopy(forKey: key))

        #expect(store.value(account: key, synchronizable: false) == "local")
        #expect(store.value(account: key, synchronizable: true) == nil)
    }

    @Test("Removing the synced copy is refused while this Mac has no item of its own")
    func removingTheSyncedCopyIsRefusedWithoutALocalItem() {
        store.seed("synced", account: key, synchronizable: true)

        #expect(!helper(passwordSync: true).removeSyncedCopy(forKey: key))

        #expect(store.value(account: key, synchronizable: true) == "synced")
    }

    @Test("ICloudSyncAllowed=false writes device-only items, and a synced item already written stays and is read")
    func managedICloudOffWritesDeviceOnly() {
        store.seed("from-another-device", account: key, synchronizable: true)
        let keychain = KeychainHelper(
            service: "com.TablePro.tests.scope",
            passwordSyncSetting: { KeychainHelper.storedPasswordSyncSetting(policy: ICloudSyncOff()) },
            items: store
        )

        #expect(keychain.readString(forKey: key) == "from-another-device")
        #expect(keychain.writeString("new", forKey: key))

        #expect(store.value(account: key, synchronizable: false) == "new")
        #expect(store.value(account: key, synchronizable: true) == "from-another-device")
    }
}

private struct ICloudSyncOff: ManagedPolicyReading {
    func string(_ policy: ManagedPolicy) -> String? { nil }
    func bool(_ policy: ManagedPolicy) -> Bool? { policy == .iCloudSyncAllowed ? false : nil }
}
