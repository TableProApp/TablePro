//
//  KeychainHelper.swift
//  TablePro
//

import Foundation
import os
import Security

enum KeychainResult: Sendable, Equatable {
    case found(Data)
    case notFound
    case locked
}

enum KeychainStringResult: Sendable, Equatable {
    case found(String)
    case notFound
    case locked
}

final class KeychainHelper: Sendable {
    static let shared = KeychainHelper()
    static let passwordSyncEnabledKey = "com.TablePro.keychainPasswordSyncEnabled"

    private let service = "com.TablePro"
    private let accessGroup: String? = KeychainHelper.resolveAccessGroup()
    private static let logger = Logger(subsystem: "com.TablePro", category: "KeychainHelper")

    private static let accessGroupSuffix = ".com.TablePro.shared"
    private static let teamPrefixedGroupPattern = #"^[A-Z0-9]{10}\..+"#

    private static func resolveAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String]
        else { return nil }
        let candidate = groups.first { $0.hasSuffix(accessGroupSuffix) } ?? groups.first
        guard let candidate,
              candidate.range(of: teamPrefixedGroupPattern, options: .regularExpression) != nil
        else { return nil }
        return candidate
    }

    private var isPasswordSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.passwordSyncEnabledKey)
    }

    private init() {}

    // MARK: - Data API

    @discardableResult
    func write(_ data: Data, forKey key: String) -> Bool {
        let synchronizable = isPasswordSyncEnabled
        let accessible = accessibility(forSync: synchronizable)

        var addQuery = baseQuery(forKey: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = accessible
        if synchronizable {
            addQuery[kSecAttrSynchronizable as String] = true
        }

        var status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecDuplicateItem {
            var search = baseQuery(forKey: key)
            search[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrSynchronizable as String: synchronizable,
                kSecAttrAccessible as String: accessible
            ]
            status = SecItemUpdate(search as CFDictionary, attributes as CFDictionary)
        }

        if status != errSecSuccess {
            log(status: status, operation: "write", key: key)
            return false
        }
        return true
    }

    func read(forKey key: String) -> KeychainResult {
        var query = baseQuery(forKey: key)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            if let data = result as? Data {
                return .found(data)
            }
            return .notFound
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            Self.logger.warning("Keychain locked (before first unlock) for '\(key, privacy: .public)'")
            return .locked
        default:
            log(status: status, operation: "read", key: key)
            return .notFound
        }
    }

    func delete(forKey key: String) {
        var query = baseQuery(forKey: key)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            log(status: status, operation: "delete", key: key)
        }
    }

    // MARK: - String Convenience

    @discardableResult
    func writeString(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            Self.logger.error("UTF-8 encode failed for '\(key, privacy: .public)'")
            return false
        }
        return write(data, forKey: key)
    }

    func readString(forKey key: String) -> String? {
        if case .found(let value) = readStringResult(forKey: key) {
            return value
        }
        return nil
    }

    func readStringResult(forKey key: String) -> KeychainStringResult {
        switch read(forKey: key) {
        case .found(let data):
            guard let value = String(data: data, encoding: .utf8) else {
                Self.logger.error("UTF-8 decode failed for '\(key, privacy: .public)'")
                return .notFound
            }
            return .found(value)
        case .notFound:
            return .notFound
        case .locked:
            return .locked
        }
    }

    // MARK: - Private

    private func baseQuery(forKey key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func accessibility(forSync synchronizable: Bool) -> CFString {
        synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    private func log(status: OSStatus, operation: String, key: String) {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        Self.logger.error(
            "Keychain \(operation, privacy: .public) failed for '\(key, privacy: .public)': \(message, privacy: .public)"
        )
    }
}
