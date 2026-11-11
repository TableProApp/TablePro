import Foundation
import Security
@testable import TablePro
import Testing

// Models what the helper depends on: synchronizable is part of an item's identity, and each write dates its item.
private final class ScopedItemStore: KeychainItemStore, @unchecked Sendable {
    struct ItemID: Hashable {
        let account: String
        let synchronizable: Bool
    }

    private struct Item {
        let data: Data
        let modified: Date
    }

    private let lock = NSLock()
    private var items: [ItemID: Item] = [:]
    private var writes = 0

    private func nextDate() -> Date {
        writes += 1
        return Date(timeIntervalSinceReferenceDate: TimeInterval(writes))
    }

    func seed(_ value: String, account: String, synchronizable: Bool) {
        lock.lock()
        defer { lock.unlock() }
        items[ItemID(account: account, synchronizable: synchronizable)] = Item(data: Data(value.utf8), modified: nextDate())
    }

    func value(account: String, synchronizable: Bool) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return items[ItemID(account: account, synchronizable: synchronizable)].map {
            String(decoding: $0.data, as: UTF8.self)
        }
    }

    private func matches(_ query: [String: Any]) -> [ItemID] {
        let account = query[kSecAttrAccount as String] as? String ?? ""
        let scopes: [Bool]
        if let scope = query[kSecAttrSynchronizable as String] {
            scopes = (scope as? Bool).map { [$0] } ?? [false, true]
        } else {
            scopes = [false]
        }
        return scopes
            .map { ItemID(account: account, synchronizable: $0) }
            .filter { items[$0] != nil }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        let id = ItemID(
            account: attributes[kSecAttrAccount as String] as? String ?? "",
            synchronizable: attributes[kSecAttrSynchronizable as String] as? Bool ?? false
        )
        guard items[id] == nil else { return errSecDuplicateItem }
        items[id] = Item(data: attributes[kSecValueData as String] as? Data ?? Data(), modified: nextDate())
        return errSecSuccess
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        let found = matches(query)
        guard !found.isEmpty else { return errSecItemNotFound }
        // Two items for one key cannot both take one synchronizable value.
        if attributes[kSecAttrSynchronizable as String] != nil, found.count > 1 {
            return errSecDuplicateItem
        }
        for id in found {
            items[id] = Item(data: attributes[kSecValueData as String] as? Data ?? Data(), modified: nextDate())
        }
        return errSecSuccess
    }

    func copyItem(_ query: [String: Any]) -> KeychainCopiedItem {
        lock.lock()
        defer { lock.unlock() }
        guard let id = matches(query).first, let item = items[id] else {
            return KeychainCopiedItem(status: errSecItemNotFound, data: nil, modified: nil)
        }
        return KeychainCopiedItem(status: errSecSuccess, data: item.data, modified: item.modified)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        let found = matches(query)
        guard !found.isEmpty else { return errSecItemNotFound }
        for id in found {
            items[id] = nil
        }
        return errSecSuccess
    }
}

struct KeychainItemScopeTests {
    private let store = ScopedItemStore()
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
}
