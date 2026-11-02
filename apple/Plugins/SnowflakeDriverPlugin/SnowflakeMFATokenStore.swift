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
import TableProSnowflakeCore

enum SnowflakeMFATokenStore {
    private struct TokenState {
        var cache: [String: String] = [:]
        var rejectedPasscodes: [String: Date] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: TokenState())
    private static let service = "com.TablePro.SnowflakeDriverPlugin.mfaToken"
    private static let logger = Logger(subsystem: "com.TablePro", category: "SnowflakeMFATokenStore")

    static func token(for account: SnowflakeAccount, user: String) -> String? {
        let key = account.tokenKey(user: user)
        if let cached = state.withLock({ $0.cache[key] }) {
            return cached
        }
        if let stored = readKeychain(key: key) {
            state.withLock { $0.cache[key] = stored }
            return stored
        }
        guard let legacyKey = account.legacyTokenKey(user: user), let legacy = readKeychain(key: legacyKey) else {
            return nil
        }
        state.withLock { $0.cache[key] = legacy }
        if writeKeychain(legacy, key: key) {
            deleteKeychain(key: legacyKey)
        }
        return legacy
    }

    static func store(_ token: String, for account: SnowflakeAccount, user: String) {
        let key = account.tokenKey(user: user)
        state.withLock { $0.cache[key] = token }
        writeKeychain(token, key: key)
    }

    static func clear(for account: SnowflakeAccount, user: String) {
        let key = account.tokenKey(user: user)
        state.withLock { $0.cache[key] = nil }
        deleteKeychain(key: key)
        if let legacyKey = account.legacyTokenKey(user: user) {
            deleteKeychain(key: legacyKey)
        }
    }

    static let rejectedPasscodeLifetime: TimeInterval = 300

    static func markPasscodeRejected(_ passcode: String, for account: SnowflakeAccount, user: String) {
        guard !passcode.isEmpty else { return }
        let key = "\(account.tokenKey(user: user)):\(passcode)"
        state.withLock { state in
            state.rejectedPasscodes = state.rejectedPasscodes.filter {
                Date().timeIntervalSince($0.value) < rejectedPasscodeLifetime
            }
            state.rejectedPasscodes[key] = Date()
        }
    }

    static func isPasscodeRejected(_ passcode: String, for account: SnowflakeAccount, user: String) -> Bool {
        guard !passcode.isEmpty else { return false }
        let key = "\(account.tokenKey(user: user)):\(passcode)"
        return state.withLock {
            guard let rejectedAt = $0.rejectedPasscodes[key] else { return false }
            return Date().timeIntervalSince(rejectedAt) < rejectedPasscodeLifetime
        }
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

    @discardableResult
    private static func writeKeychain(_ value: String, key: String) -> Bool {
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
        return status == errSecSuccess
    }

    private static func deleteKeychain(key: String) {
        SecItemDelete(baseQuery(key: key) as CFDictionary)
    }
}
