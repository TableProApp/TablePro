import Foundation
import Security
@testable import TablePro
import Testing

// Models the one rule the helper depends on: synchronizable is part of an item's identity.
private final class ScopedItemStore: KeychainItemStore, @unchecked Sendable {
    struct ItemID: Hashable {
        let account: String
        let synchronizable: Bool
    }

    private let lock = NSLock()
    private var items: [ItemID: Data] = [:]

    func seed(_ value: String, account: String, synchronizable: Bool) {
        lock.lock()
        defer { lock.unlock() }
        items[ItemID(account: account, synchronizable: synchronizable)] = Data(value.utf8)
    }

    func value(account: String, synchronizable: Bool) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return items[ItemID(account: account, synchronizable: synchronizable)].map { String(decoding: $0, as: UTF8.self) }
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
        items[id] = attributes[kSecValueData as String] as? Data
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
            items[id] = attributes[kSecValueData as String] as? Data
        }
        return errSecSuccess
    }

    func copyData(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        guard let id = matches(query).first else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, items[id])
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

    @Test("A read returns the item the setting selects when both exist")
    func readPrefersTheSelectedItem() {
        store.seed("local", account: key, synchronizable: false)
        store.seed("synced", account: key, synchronizable: true)

        #expect(helper(passwordSync: true).readString(forKey: key) == "synced")
        #expect(helper(passwordSync: false).readString(forKey: key) == "local")
    }

    @Test("Delete removes both items")
    func deleteRemovesBothItems() {
        store.seed("local", account: key, synchronizable: false)
        store.seed("synced", account: key, synchronizable: true)
        let keychain = helper(passwordSync: false)

        keychain.delete(forKey: key)

        #expect(keychain.readStringResult(forKey: key) == .notFound)
    }
}
