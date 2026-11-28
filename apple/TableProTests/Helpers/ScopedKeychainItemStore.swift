import Foundation
import Security
@testable import TablePro

// Models what `KeychainHelper` depends on: synchronizable is part of an item's identity, and each write dates its item.
final class ScopedKeychainItemStore: KeychainItemStore, @unchecked Sendable {
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
    private var lockedAccounts: Set<String> = []
    private var refusedDeletes: Set<String> = []
    private var listingLocked = false

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

    // A read of the account answers as a locked keychain does, before the first unlock.
    func lockItems(of account: String) {
        lock.lock()
        defer { lock.unlock() }
        lockedAccounts.insert(account)
    }

    func unlockItems(of account: String) {
        lock.lock()
        defer { lock.unlock() }
        lockedAccounts.remove(account)
    }

    // A delete of the account fails as a keychain that refuses it does, until `refuseDeletes(of:false)`.
    func refuseDeletes(of account: String, _ refused: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        if refused {
            refusedDeletes.insert(account)
        } else {
            refusedDeletes.remove(account)
        }
    }

    func lockListing(_ locked: Bool) {
        lock.lock()
        defer { lock.unlock() }
        listingLocked = locked
    }

    private func scopes(_ query: [String: Any]) -> [Bool] {
        guard let scope = query[kSecAttrSynchronizable as String] else { return [false] }
        return (scope as? Bool).map { [$0] } ?? [false, true]
    }

    private func matches(_ query: [String: Any]) -> [ItemID] {
        let account = query[kSecAttrAccount as String] as? String ?? ""
        return scopes(query)
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
        if let account = query[kSecAttrAccount as String] as? String, lockedAccounts.contains(account) {
            return KeychainCopiedItem(status: errSecInteractionNotAllowed, data: nil, modified: nil)
        }
        guard let id = matches(query).first, let item = items[id] else {
            return KeychainCopiedItem(status: errSecItemNotFound, data: nil, modified: nil)
        }
        return KeychainCopiedItem(status: errSecSuccess, data: item.data, modified: item.modified)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        if let account = query[kSecAttrAccount as String] as? String, refusedDeletes.contains(account) {
            return errSecInteractionNotAllowed
        }
        let found = matches(query)
        guard !found.isEmpty else { return errSecItemNotFound }
        for id in found {
            items[id] = nil
        }
        return errSecSuccess
    }

    func accountList(_ query: [String: Any]) -> KeychainAccountList {
        lock.lock()
        defer { lock.unlock() }
        guard !listingLocked else { return KeychainAccountList(status: errSecInteractionNotAllowed, accounts: []) }
        let wanted = Set(scopes(query))
        let accounts = items.keys.filter { wanted.contains($0.synchronizable) }.map(\.account).sorted()
        return KeychainAccountList(status: errSecSuccess, accounts: accounts)
    }
}
