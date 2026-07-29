import Foundation
import os
import Security
import TableProDatabase

final class KeychainSecureStore: SecureStore {
    private static let logger = Logger(subsystem: "com.TablePro", category: "KeychainSecureStore")

    private let serviceName = "com.TablePro"
    private let accessGroup: String?

    private static var cachedAccessGroup: String?

    private static func resolveAccessGroup() -> String? {
        if let cached = cachedAccessGroup { return cached }

        guard let prefix = Bundle.main.infoDictionary?["AppIdentifierPrefix"] as? String,
              !prefix.isEmpty,
              !prefix.hasPrefix("$(") else {
            logger.warning("AppIdentifierPrefix unavailable; using the app-local keychain without a shared access group (expected for unsigned or test builds; in a signed build, widget keychain sharing is off).")
            return nil
        }

        let group = "\(prefix)com.TablePro.shared"
        cachedAccessGroup = group
        return group
    }

    init() {
        self.accessGroup = Self.resolveAccessGroup()
    }

    private func applyingAccessGroup(_ query: [String: Any]) -> [String: Any] {
        guard let accessGroup else { return query }
        var query = query
        query[kSecAttrAccessGroup as String] = accessGroup
        return query
    }

    func store(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(applyingAccessGroup(deleteQuery) as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(applyingAccessGroup(addQuery) as CFDictionary, nil)
        if status != errSecSuccess {
            throw KeychainError.storeFailed(status)
        }
    }

    func retrieve(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
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
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(applyingAccessGroup(query) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Remove orphaned test connection credentials that may remain after a SIGKILL.
    /// Test credentials use temp UUIDs not associated with any saved connection.
    func cleanOrphanedCredentials(validConnectionIds: Set<UUID>) {
        let prefixes = ["com.TablePro.password.", "com.TablePro.sshpassword.", "com.TablePro.keypassphrase."]
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(applyingAccessGroup(query) as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            for prefix in prefixes {
                guard account.hasPrefix(prefix) else { continue }
                let uuidString = String(account.dropFirst(prefix.count))
                guard let uuid = UUID(uuidString: uuidString),
                      !validConnectionIds.contains(uuid) else { continue }
                try? delete(forKey: account)
            }
        }
    }
}

enum KeychainError: Error, LocalizedError {
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
