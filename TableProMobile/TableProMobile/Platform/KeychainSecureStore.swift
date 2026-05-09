import Foundation
import Security
import TableProDatabase

final class KeychainSecureStore: SecureStore {
    private let serviceName = "com.TablePro"
    private let accessGroup: String

    private static var cachedAccessGroup: String?

    private static func resolveAccessGroup() -> String {
        if let cached = cachedAccessGroup { return cached }

        // Read team ID prefix from provisioning at runtime
        if let seedID = Bundle.main.infoDictionary?["AppIdentifierPrefix"] as? String {
            let group = "\(seedID)com.TablePro.shared"
            cachedAccessGroup = group
            return group
        }
        // Fallback: query Keychain for the app's default access group
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "__accessgroup_probe__",
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        SecItemAdd(query as CFDictionary, &result)
        SecItemDelete(query as CFDictionary)
        if let attrs = result as? [String: Any],
           let group = attrs[kSecAttrAccessGroup as String] as? String {
            let prefix = group.components(separatedBy: ".").first ?? ""
            let resolved = "\(prefix).com.TablePro.shared"
            cachedAccessGroup = resolved
            return resolved
        }
        // Use non-shared access group as last resort — credentials won't sync
        // across devices but the app still functions
        let fallback = "com.TablePro.shared"
        cachedAccessGroup = fallback
        return fallback
    }

    init() {
        self.accessGroup = Self.resolveAccessGroup()
    }

    func store(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            throw KeychainError.storeFailed(status)
        }
    }

    func retrieve(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

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
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
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
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
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
