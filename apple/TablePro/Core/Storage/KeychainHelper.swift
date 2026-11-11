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
    case userCancelled
    case authFailed
    case error(OSStatus)
}

enum KeychainStringResult: Sendable, Equatable {
    case found(String)
    case notFound
    case locked
    case userCancelled
    case authFailed
    case error(OSStatus)
}

protocol KeychainStoring: Sendable {
    @discardableResult
    func writeString(_ value: String, forKey key: String) -> Bool
    // deviceOnly keeps the item out of iCloud Keychain whatever the password sync setting says.
    @discardableResult
    func writeString(_ value: String, forKey key: String, deviceOnly: Bool) -> Bool
    func readStringResult(forKey key: String) -> KeychainStringResult
    // deviceOnly reads this Mac's own item before one iCloud Keychain delivered.
    func readStringResult(forKey key: String, deviceOnly: Bool) -> KeychainStringResult
    func delete(forKey key: String)
    // deviceOnly removes this Mac's own item and leaves the one iCloud Keychain holds, which every device shares.
    func delete(forKey key: String, deviceOnly: Bool)
}

extension KeychainStoring {
    func readStringResult(forKey key: String, deviceOnly: Bool) -> KeychainStringResult {
        readStringResult(forKey: key)
    }

    func delete(forKey key: String, deviceOnly: Bool) {
        delete(forKey: key)
    }

    @discardableResult
    func writeString(_ value: String, forKey key: String, deviceOnly: Bool) -> Bool {
        writeString(value, forKey: key)
    }
}

struct KeychainCopiedItem: Sendable {
    let status: OSStatus
    let data: Data?
    let modified: Date?
}

protocol KeychainItemStore: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    // The first item the query matches, with its data and modification date.
    func copyItem(_ query: [String: Any]) -> KeychainCopiedItem
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainItemStore: KeychainItemStore {
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

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

final class KeychainHelper: KeychainStoring {
    static let shared = KeychainHelper()
    static let passwordSyncEnabledKey = "com.TablePro.keychainPasswordSyncEnabled"

    private let service: String
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

    // Off for a credential bound to this Mac, which another Mac must never receive through iCloud.
    private let followsPasswordSync: Bool
    private let passwordSyncSetting: @Sendable () -> Bool
    private let items: any KeychainItemStore

    private var isPasswordSyncEnabled: Bool {
        followsPasswordSync && passwordSyncSetting()
    }

    static func storedPasswordSyncSetting() -> Bool {
        AppStorageEnvironment.shared.defaults.bool(forKey: passwordSyncEnabledKey)
    }

    init(
        service: String = "com.TablePro",
        followsPasswordSync: Bool = true,
        passwordSyncSetting: @escaping @Sendable () -> Bool = { KeychainHelper.storedPasswordSyncSetting() },
        items: any KeychainItemStore = SystemKeychainItemStore()
    ) {
        self.service = service
        self.followsPasswordSync = followsPasswordSync
        self.passwordSyncSetting = passwordSyncSetting
        self.items = items
    }

    // MARK: - Data API

    @discardableResult
    func write(_ data: Data, forKey key: String) -> Bool {
        write(data, forKey: key, deviceOnly: false)
    }

    // Synchronizable is part of an item's identity, so a key can hold a synced and a local item at once. The write
    // goes to the one the setting selects. A synced item is never removed here: deleting it reaches every device.
    @discardableResult
    func write(_ data: Data, forKey key: String, deviceOnly: Bool) -> Bool {
        let synchronizable = !deviceOnly && isPasswordSyncEnabled
        let accessible = accessibility(forSync: synchronizable)
        let target = itemQuery(forKey: key, synchronizable: synchronizable)

        var status = items.update(target, attributes: [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ])
        if status == errSecItemNotFound {
            var attributes = target
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = accessible
            status = items.add(attributes)
        }

        if status != errSecSuccess {
            log(status: status, operation: "write", key: key)
            return false
        }

        if synchronizable {
            let stale = items.delete(itemQuery(forKey: key, synchronizable: false))
            if stale != errSecSuccess, stale != errSecItemNotFound {
                log(status: stale, operation: "remove the local copy", key: key)
            }
        }
        return true
    }

    func read(forKey key: String) -> KeychainResult {
        read(forKey: key, deviceOnly: false)
    }

    // With sync on, a newer local item is a save made while sync was off; with sync off, this Mac's own item always wins.
    func read(forKey key: String, deviceOnly: Bool) -> KeychainResult {
        let prefersSynced = !deviceOnly && isPasswordSyncEnabled
        let first = items.copyItem(itemQuery(forKey: key, synchronizable: prefersSynced))
        guard first.status == errSecItemNotFound else {
            guard first.status == errSecSuccess, prefersSynced else {
                return result(for: first, key: key)
            }
            let other = items.copyItem(itemQuery(forKey: key, synchronizable: !prefersSynced))
            return result(for: Self.isNewer(other, than: first) ? other : first, key: key)
        }

        var fallback = baseQuery(forKey: key)
        fallback[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        return result(for: items.copyItem(fallback), key: key)
    }

    private static func isNewer(_ candidate: KeychainCopiedItem, than current: KeychainCopiedItem) -> Bool {
        guard candidate.status == errSecSuccess, let candidateDate = candidate.modified,
              let currentDate = current.modified else { return false }
        return candidateDate > currentDate
    }

    private func result(for copied: KeychainCopiedItem, key: String) -> KeychainResult {
        switch copied.status {
        case errSecSuccess:
            if let data = copied.data {
                return .found(data)
            }
            return .notFound
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            Self.logger.warning("Keychain locked (before first unlock) for '\(key, privacy: .public)'")
            return .locked
        case errSecUserCanceled:
            Self.logger.notice("Keychain prompt cancelled for '\(key, privacy: .public)'")
            return .userCancelled
        case errSecAuthFailed:
            Self.logger.warning("Keychain auth failed for '\(key, privacy: .public)'")
            return .authFailed
        default:
            log(status: copied.status, operation: "read", key: key)
            return .error(copied.status)
        }
    }

    func delete(forKey key: String) {
        delete(forKey: key, deviceOnly: false)
    }

    func delete(forKey key: String, deviceOnly: Bool) {
        var query = baseQuery(forKey: key)
        if !deviceOnly {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }

        let status = items.delete(query)
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
        return write(data, forKey: key, deviceOnly: false)
    }

    @discardableResult
    func writeString(_ value: String, forKey key: String, deviceOnly: Bool) -> Bool {
        guard let data = value.data(using: .utf8) else {
            Self.logger.error("UTF-8 encode failed for '\(key, privacy: .public)'")
            return false
        }
        return write(data, forKey: key, deviceOnly: deviceOnly)
    }

    func readString(forKey key: String) -> String? {
        if case .found(let value) = readStringResult(forKey: key) {
            return value
        }
        return nil
    }

    func readStringResult(forKey key: String) -> KeychainStringResult {
        readStringResult(forKey: key, deviceOnly: false)
    }

    func readStringResult(forKey key: String, deviceOnly: Bool) -> KeychainStringResult {
        switch read(forKey: key, deviceOnly: deviceOnly) {
        case .found(let data):
            guard let value = String(data: data, encoding: .utf8) else {
                Self.logger.error("UTF-8 decode failed for '\(key, privacy: .public)'")
                return .error(errSecDecode)
            }
            return .found(value)
        case .notFound: return .notFound
        case .locked: return .locked
        case .userCancelled: return .userCancelled
        case .authFailed: return .authFailed
        case .error(let status): return .error(status)
        }
    }

    // MARK: - Private

    // No synchronizable key matches local items only, in the file-based keychain too.
    private func itemQuery(forKey key: String, synchronizable: Bool) -> [String: Any] {
        var query = baseQuery(forKey: key)
        if synchronizable {
            query[kSecAttrSynchronizable as String] = true
        }
        return query
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if Self.canUseDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static let canUseDataProtectionKeychain: Bool = {
        #if DEBUG
        guard let task = SecTaskCreateFromSelf(nil),
              SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) != nil
        else {
            logger.warning("No application-identifier entitlement; falling back to the file-based keychain (DEBUG build)")
            return false
        }
        return true
        #else
        return true
        #endif
    }()

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
