//
//  KeychainHelper.swift
//  TablePro
//

import Foundation
import os
import Security

enum KeychainLoadResult {
    case success(Data)
    case notFound
    case locked
    case error(OSStatus)
}

final class KeychainHelper {
    static let shared = KeychainHelper()

    private let service = "com.TablePro"
    private let accessGroup = "D7HJ5TFYCU.com.TablePro.shared"
    private static let logger = Logger(subsystem: "com.TablePro", category: "KeychainHelper")
    private static let migrationKey = "com.TablePro.keychainMigratedToDataProtection"
    static let passwordSyncEnabledKey = "com.TablePro.keychainPasswordSyncEnabled"

    private let migrationLock = NSLock()

    private var isPasswordSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.passwordSyncEnabledKey)
    }

    private init() {}

    // MARK: - Core Methods

    @discardableResult
    func save(key: String, data: Data) -> Bool {
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecValueData as String: data,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if isPasswordSyncEnabled {
            addQuery[kSecAttrSynchronizable as String] = true
        }

        var status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let synchronizable = isPasswordSyncEnabled
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecAttrAccessGroup as String: accessGroup,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrSynchronizable as String: synchronizable
            ]
            status = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
        }

        if status != errSecSuccess {
            Self.logger.error("Failed to save keychain item for key '\(key, privacy: .public)': \(status)")
        }

        return status == errSecSuccess
    }

    func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Self.logger.error("Failed to load keychain item for key '\(key, privacy: .public)': \(status)")
            }
            return nil
        }

        return result as? Data
    }

    func loadWithStatus(key: String) -> KeychainLoadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            if let data = result as? Data {
                return .success(data)
            }
            return .notFound
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            Self.logger.warning("Keychain locked (before first unlock) for key '\(key, privacy: .public)'")
            return .locked
        default:
            Self.logger.error("Keychain error for key '\(key, privacy: .public)': \(status)")
            return .error(status)
        }
    }

    func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        let status = SecItemDelete(query as CFDictionary)

        if status != errSecSuccess, status != errSecItemNotFound {
            Self.logger.error("Failed to delete keychain item for key '\(key, privacy: .public)': \(status)")
        }
    }

    // MARK: - String Convenience

    @discardableResult
    func saveString(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            Self.logger.error("Failed to encode string to UTF-8 for key '\(key, privacy: .public)'")
            return false
        }
        return save(key: key, data: data)
    }

    func loadString(forKey key: String) -> String? {
        guard let data = load(key: key) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func loadStringWithStatus(forKey key: String) -> (value: String?, isLocked: Bool) {
        switch loadWithStatus(key: key) {
        case .success(let data):
            return (String(data: data, encoding: .utf8), false)
        case .locked:
            return (nil, true)
        case .notFound, .error:
            return (nil, false)
        }
    }

    // MARK: - Migration

    func migrateFromLegacyKeychainIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.migrationKey) else {
            return
        }

        Self.logger.info("Starting legacy keychain migration to Data Protection keychain")

        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)

        if status == errSecItemNotFound {
            Self.logger.info("No legacy keychain items found, marking migration as complete")
            UserDefaults.standard.set(true, forKey: Self.migrationKey)
            return
        }

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            Self.logger.error("Failed to query legacy keychain items: \(status)")
            return
        }

        Self.logger.info("Found \(items.count) legacy keychain items to migrate")

        var allSucceeded = true

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else {
                Self.logger.warning("Skipping legacy item with missing account or data")
                allSucceeded = false
                continue
            }

            let saved = save(key: account, data: data)

            if saved {
                let deleteLegacyQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account
                ]
                let deleteStatus = SecItemDelete(deleteLegacyQuery as CFDictionary)

                if deleteStatus != errSecSuccess, deleteStatus != errSecItemNotFound {
                    Self.logger.warning(
                        "Migrated item '\(account, privacy: .public)' but failed to delete legacy entry: \(deleteStatus)"
                    )
                } else {
                    Self.logger.info("Successfully migrated item '\(account, privacy: .public)'")
                }
            } else {
                Self.logger.error("Failed to migrate item '\(account, privacy: .public)' to Data Protection keychain")
                allSucceeded = false
            }
        }

        if allSucceeded {
            UserDefaults.standard.set(true, forKey: Self.migrationKey)
            Self.logger.info("Legacy keychain migration completed successfully")
        } else {
            Self.logger.warning("Legacy keychain migration incomplete, will retry on next launch")
        }
    }

    // MARK: - Password Sync Migration

    /// Migrates all TablePro keychain items between local-only and iCloud-synchronizable.
    /// Serialized via `migrationLock` to prevent concurrent migrations from rapid toggling.
    func migratePasswordSyncState(synchronizable: Bool) {
        migrationLock.lock()
        defer { migrationLock.unlock() }

        Self.logger.info("Starting keychain sync migration: synchronizable=\(synchronizable)")

        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(searchQuery as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status == errSecItemNotFound {
                Self.logger.info("No keychain items to migrate")
            } else {
                Self.logger.error("Failed to query items for sync migration: \(status)")
            }
            return
        }

        var migratedCount = 0
        var skippedCount = 0

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data
            else { continue }

            let currentlySync = item[kSecAttrSynchronizable as String] as? Bool ?? false
            if currentlySync == synchronizable {
                skippedCount += 1
                continue
            }

            var addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            if synchronizable {
                addQuery[kSecAttrSynchronizable as String] = true
            }

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

            guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
                Self.logger.error(
                    "Failed to create migrated item '\(account, privacy: .public)': \(addStatus)"
                )
                continue
            }

            // When opting IN (synchronizable=true), delete the old local-only item safely.
            // When opting OUT (synchronizable=false), keep the synchronizable item — deleting it
            // would propagate via iCloud Keychain and remove it from other Macs still opted in.
            if synchronizable {
                let deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                    kSecUseDataProtectionKeychain as String: true,
                    kSecAttrSynchronizable as String: false
                ]
                let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
                if deleteStatus != errSecSuccess, deleteStatus != errSecItemNotFound {
                    Self.logger.warning(
                        "Migrated item '\(account, privacy: .public)' but failed to delete old entry: \(deleteStatus)"
                    )
                }
            }

            migratedCount += 1
        }

        Self.logger.info(
            "Keychain sync migration complete: \(migratedCount) migrated, \(skippedCount) already correct"
        )
    }
}
