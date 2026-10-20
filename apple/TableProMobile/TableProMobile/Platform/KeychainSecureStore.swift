import Foundation
import os
import Security
import TableProDatabase

nonisolated final class KeychainSecureStore: SecureStore {
    private static let logger = Logger(subsystem: "com.TablePro", category: "KeychainSecureStore")

    private static let serviceName = "com.TablePro"
    private let accessGroup: String?

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

    init() {
        self.accessGroup = Self.resolveAccessGroup()
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

    func store(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        let synchronizable = Self.synchronizes(key, syncsPasswords: AppPreferences.syncsPasswords)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(applyingAccessGroup(deleteQuery) as CFDictionary)

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.accessibility(forSync: synchronizable),
            kSecUseDataProtectionKeychain as String: true,
        ]
        if synchronizable {
            addQuery[kSecAttrSynchronizable as String] = true
        }
        let status = SecItemAdd(applyingAccessGroup(addQuery) as CFDictionary, nil)
        if status != errSecSuccess {
            throw KeychainError.storeFailed(status)
        }
    }

    func retrieve(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(applyingAccessGroup(query) as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess {
            throw KeychainError.retrieveFailed(status)
        }

        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(applyingAccessGroup(query) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.deleteFailed(status)
        }
    }

    // Device-local items only: deleting a synced one here would remove it from the Mac that wrote it.
    static func cleanOrphanedCredentials(validConnectionIds: Set<UUID>) {
        guard !validConnectionIds.isEmpty else { return }

        let accessGroup = resolveAccessGroup()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(applying(accessGroup: accessGroup, to: query) as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }

        let accounts = items.compactMap { $0[kSecAttrAccount as String] as? String }
        for account in ConnectionSecretKind.orphanedAccounts(accounts, keeping: validConnectionIds) {
            deleteDeviceLocal(forKey: account, accessGroup: accessGroup)
        }
    }

    // Unlike delete(forKey:), never matches a synced item of the same name.
    private static func deleteDeviceLocal(forKey key: String, accessGroup: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(applying(accessGroup: accessGroup, to: query) as CFDictionary)
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
