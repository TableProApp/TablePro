//
//  SnowflakeIdTokenStore.swift
//  SnowflakeDriverPlugin
//
//  Caches the idToken Snowflake issues after a successful external-browser SSO
//  login (CLIENT_STORE_TEMPORARY_CREDENTIAL), so subsequent connects use the
//  ID_TOKEN authenticator instead of reopening the browser. Mirrors the
//  official connectors' temporary credential cache, stored in the Keychain.
//

import Foundation
import os
import Security

enum SnowflakeIdTokenStore {
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]
    private static let service = "com.TablePro.SnowflakeDriverPlugin.idToken"
    private static let logger = Logger(subsystem: "com.TablePro", category: "SnowflakeIdTokenStore")

    static func token(account: String, user: String) -> String? {
        let key = cacheKey(account: account, user: user)
        if let cached = lock.withLock({ cache[key] }) {
            return cached
        }
        guard let stored = readKeychain(key: key) else { return nil }
        lock.withLock { cache[key] = stored }
        return stored
    }

    static func store(_ token: String, account: String, user: String) {
        let key = cacheKey(account: account, user: user)
        lock.withLock { cache[key] = token }
        writeKeychain(token, key: key)
    }

    static func clear(account: String, user: String) {
        let key = cacheKey(account: account, user: user)
        _ = lock.withLock { cache.removeValue(forKey: key) }
        deleteKeychain(key: key)
    }

    private static func cacheKey(account: String, user: String) -> String {
        "\(SnowflakeAccount.issuerAccountName(forAccount: account)).\(user.uppercased())"
    }

    private static func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    private static func readKeychain(key: String) -> String? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ value: String, key: String) {
        var addQuery = baseQuery(key: key)
        addQuery[kSecValueData as String] = Data(value.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(
                baseQuery(key: key) as CFDictionary,
                [kSecValueData as String: Data(value.utf8)] as CFDictionary
            )
        }
        if status != errSecSuccess {
            logger.warning("Could not persist SSO id token (OSStatus \(status)); it will be cached in memory only")
        }
    }

    private static func deleteKeychain(key: String) {
        SecItemDelete(baseQuery(key: key) as CFDictionary)
    }
}
