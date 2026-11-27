import Foundation
import os
import Security
import TableProDatabase

nonisolated struct KeychainCopiedItem: Sendable {
    let status: OSStatus
    let data: Data?
    let modified: Date?
}

nonisolated protocol KeychainItemStore: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    // The first item the query matches, with its data and modification date.
    func copyItem(_ query: [String: Any]) -> KeychainCopiedItem
    // Every item's account the query matches; none when the read fails.
    func accounts(_ query: [String: Any]) -> [String]
    func delete(_ query: [String: Any]) -> OSStatus
}

nonisolated struct SystemKeychainItemStore: KeychainItemStore {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func copyItem(_ query: [String: Any]) -> KeychainCopiedItem {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let item = result as? [String: Any]
        return KeychainCopiedItem(
            status: status,
            data: item?[kSecValueData as String] as? Data,
            modified: item?[kSecAttrModificationDate as String] as? Date
        )
    }

    func accounts(_ query: [String: Any]) -> [String] {
        var query = query
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

nonisolated final class KeychainSecureStore: SecureStore {
    private static let logger = Logger(subsystem: "com.TablePro", category: "KeychainSecureStore")

    private static let serviceName = "com.TablePro"
    private let accessGroup: String?
    private let syncsPasswords: @Sendable () -> Bool
    private let provider: any KeychainProviderRecord
    private let items: any KeychainItemStore
    // A removal and a copy of the same item never interleave, so a copy cannot bring back what was just removed.
    private let copyLock = NSLock()

    private static let cachedAccessGroup = OSAllocatedUnfairLock<String?>(initialState: nil)

    private static func resolveAccessGroup() -> String? {
        if let cached = cachedAccessGroup.withLock({ $0 }) { return cached }

        guard let prefix = Bundle.main.infoDictionary?["AppIdentifierPrefix"] as? String,
              !prefix.isEmpty,
              !prefix.hasPrefix("$(") else {
            logger.warning("""
                AppIdentifierPrefix unavailable; using the app-local keychain without a shared access group \
                (expected for unsigned or test builds; in a signed build, widget keychain sharing is off).
                """)
            return nil
        }

        let group = "\(prefix)com.TablePro.shared"
        cachedAccessGroup.withLock { $0 = group }
        return group
    }

    init(
        syncsPasswords: @escaping @Sendable () -> Bool = { AppPreferences.syncsPasswords },
        provider: any KeychainProviderRecord = DefaultsKeychainProviderRecord(),
        items: any KeychainItemStore = SystemKeychainItemStore()
    ) {
        self.accessGroup = Self.resolveAccessGroup()
        self.syncsPasswords = syncsPasswords
        self.provider = provider
        self.items = items
    }

    // Nil while the password switch decides.
    private var tableProSync: KeychainProviderState? {
        let state = provider.state
        return state.onTableProSync ? state : nil
    }

    private var syncsHere: Bool {
        tableProSync == nil && syncsPasswords()
    }

    private func applyingAccessGroup(_ query: [String: Any]) -> [String: Any] {
        Self.applying(accessGroup: accessGroup, to: query)
    }

    private static func applying(accessGroup: String?, to query: [String: Any]) -> [String: Any] {
        guard let accessGroup else { return query }
        var query = query
        query[kSecAttrAccessGroup as String] = accessGroup
        return query
    }

    static func accessibility(forSync synchronizable: Bool) -> CFString {
        synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    static func synchronizes(_ key: String, syncsPasswords: Bool) -> Bool {
        syncsPasswords && !ConnectionSecretKind.isDeviceOnly(account: key)
    }

    // Synchronizable is part of an item's identity, and deleting a synced item deletes it on every device.
    func store(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else { return }
        try copyLock.withLock { try storeUnlocked(data, forKey: key) }
    }

    private func storeUnlocked(_ data: Data, forKey key: String) throws {
        let synchronizable = Self.synchronizes(key, syncsPasswords: syncsHere)
        let accessible = Self.accessibility(forSync: synchronizable)
        let target = itemQuery(forKey: key, synchronizable: synchronizable)

        var status = items.update(target, attributes: [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
        ])
        if status == errSecItemNotFound {
            var attributes = target
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = accessible
            status = items.add(attributes)
        }
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }

        if tableProSync != nil {
            provider.noteSavedHere(key)
        }
        guard synchronizable else { return }
        let stale = items.delete(itemQuery(forKey: key, synchronizable: false))
        if stale != errSecSuccess, stale != errSecItemNotFound {
            Self.logger.error("Removing the device-only copy of '\(key, privacy: .public)' failed: \(stale)")
        }
    }

    // With sync on, a newer device-only copy is a save made while sync was off; with sync off, this device's copy wins.
    // On TablePro Sync a secret removed here stays removed: once every iCloud item has a copy here no read falls back
    // to one, and before that only to one not removed here.
    func retrieve(forKey key: String) throws -> String? {
        let preferred = Self.synchronizes(key, syncsPasswords: syncsHere)
        var found = items.copyItem(itemQuery(forKey: key, synchronizable: preferred))
        if found.status == errSecItemNotFound {
            if let state = tableProSync, state.deviceCopiesAdded || provider.isRemovedHere(key) {
                return nil
            }
            found = items.copyItem(itemQuery(forKey: key, synchronizable: !preferred))
        } else if found.status == errSecSuccess, preferred {
            let other = items.copyItem(itemQuery(forKey: key, synchronizable: !preferred))
            if Self.isNewer(other, than: found) { found = other }
        }

        if found.status == errSecItemNotFound { return nil }
        if found.status != errSecSuccess {
            throw KeychainError.retrieveFailed(found.status)
        }

        guard let data = found.data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func isNewer(_ candidate: KeychainCopiedItem, than current: KeychainCopiedItem) -> Bool {
        guard candidate.status == errSecSuccess, let candidateDate = candidate.modified,
              let currentDate = current.modified else { return false }
        return candidateDate > currentDate
    }

    // On TablePro Sync only this device's own item goes: the iCloud one belongs to the devices still on iCloud.
    func delete(forKey key: String) throws {
        try copyLock.withLock {
            var query = baseQuery(forKey: key)
            if let state = tableProSync {
                // Noted first: a stop between the two then leaves this device's item and a note a save clears, never
                // a removed item whose iCloud copy reads back.
                if !state.deviceCopiesAdded {
                    provider.noteRemovedHere(key)
                }
                query[kSecAttrSynchronizable as String] = false
            } else {
                query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            }
            let status = items.delete(query)
            if status != errSecSuccess && status != errSecItemNotFound {
                throw KeychainError.deleteFailed(status)
            }
        }
    }

    // On TablePro Sync each iCloud Keychain item gets a copy of this device's own, so a later read never needs the
    // iCloud one. False when one could not be read or written yet, such as before the first unlock.
    func addDeviceOnlyCopies() -> Bool {
        var query = baseQuery(forKey: "")
        query.removeValue(forKey: kSecAttrAccount as String)
        query[kSecAttrSynchronizable as String] = true
        var complete = true
        for key in Set(items.accounts(query)).sorted() where !addDeviceOnlyCopy(forKey: key) {
            complete = false
        }
        return complete
    }

    // Off TablePro Sync again, a copy still under way stops: the password switch decides from then on.
    private func addDeviceOnlyCopy(forKey key: String) -> Bool {
        copyLock.withLock {
            if tableProSync == nil || provider.isRemovedHere(key) {
                return true
            }
            let own = items.copyItem(itemQuery(forKey: key, synchronizable: false))
            guard own.status == errSecItemNotFound else {
                return own.status == errSecSuccess
            }
            let synced = items.copyItem(itemQuery(forKey: key, synchronizable: true))
            guard synced.status == errSecSuccess, let data = synced.data else {
                return synced.status == errSecItemNotFound
            }
            var attributes = itemQuery(forKey: key, synchronizable: false)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = Self.accessibility(forSync: false)
            let status = items.add(attributes)
            guard status == errSecSuccess || status == errSecDuplicateItem else {
                Self.logger.error("Copying the iCloud Keychain item '\(key, privacy: .public)' to this device failed: \(status)")
                return false
            }
            return true
        }
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        applyingAccessGroup([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ])
    }

    private func itemQuery(forKey key: String, synchronizable: Bool) -> [String: Any] {
        var query = baseQuery(forKey: key)
        query[kSecAttrSynchronizable as String] = synchronizable
        return query
    }

    // Device-local items only: deleting a synced one here would remove it from the Mac that wrote it.
    // The Keychain calls block, so they run off the main actor. The library is read once the listing
    // returns, and a save adds its connection before its secrets, so a connection saved meanwhile keeps them.
    @concurrent
    static func cleanOrphanedCredentials(
        items: any KeychainItemStore = SystemKeychainItemStore(),
        keeping connectionIds: @MainActor @Sendable () -> Set<UUID>?
    ) async {
        let accessGroup = resolveAccessGroup()
        let accounts = items.accounts(applying(accessGroup: accessGroup, to: [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]))
        guard !accounts.isEmpty, let kept = await connectionIds() else { return }
        for account in ConnectionSecretKind.orphanedAccounts(accounts, keeping: kept) {
            let status = items.delete(deviceLocalQuery(forKey: account, accessGroup: accessGroup))
            if status != errSecSuccess, status != errSecItemNotFound {
                logger.error("Removing a deleted connection's secret failed: \(status)")
            }
        }
    }

    // Unlike delete(forKey:), never matches a synced item of the same name.
    private static func deviceLocalQuery(forKey key: String, accessGroup: String?) -> [String: Any] {
        applying(accessGroup: accessGroup, to: [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ])
    }
}

nonisolated enum KeychainError: Error, LocalizedError {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .storeFailed(let status): return "Keychain store failed: \(status)"
        case .retrieveFailed(let status): return "Keychain retrieve failed: \(status)"
        case .deleteFailed(let status): return "Keychain delete failed: \(status)"
        }
    }
}
