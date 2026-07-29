//
//  SnowflakeMFATokenStore.swift
//  SnowflakeDriverPlugin
//
//  Caches the MFA token Snowflake issues after a successful TOTP login
//  (CLIENT_REQUEST_MFA_TOKEN), so subsequent connects don't need a fresh
//  passcode until the token expires. Mirrors the official connectors.
//

import Foundation
import os
import Security

enum SnowflakeMFATokenStore {
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]
    private static let service = "com.TablePro.SnowflakeDriverPlugin.mfaToken"
    private static let logger = Logger(subsystem: "com.TablePro", category: "SnowflakeMFATokenStore")

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

    static let rejectedPasscodeLifetime: TimeInterval = 300

    static func markPasscodeRejected(_ passcode: String, account: String, user: String) {
        guard !passcode.isEmpty else { return }
        let key = "\(cacheKey(account: account, user: user)):\(passcode)"
        lock.withLock {
            rejectedPasscodes = rejectedPasscodes.filter { Date().timeIntervalSince($0.value) < rejectedPasscodeLifetime }
            rejectedPasscodes[key] = Date()
        }
    }

    static func isPasscodeRejected(_ passcode: String, account: String, user: String) -> Bool {
        guard !passcode.isEmpty else { return false }
        let key = "\(cacheKey(account: account, user: user)):\(passcode)"
        return lock.withLock {
            guard let rejectedAt = rejectedPasscodes[key] else { return false }
            return Date().timeIntervalSince(rejectedAt) < rejectedPasscodeLifetime
        }
    }

    private static var rejectedPasscodes: [String: Date] = [:]

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
            logger.warning("Could not persist MFA token (OSStatus \(status)); it will be cached in memory only")
        }
    }

    private static func deleteKeychain(key: String) {
        SecItemDelete(baseQuery(key: key) as CFDictionary)
    }
}
