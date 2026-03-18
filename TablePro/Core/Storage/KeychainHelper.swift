//
//  KeychainHelper.swift
//  TablePro
//

import Foundation
import os
import Security

final class KeychainHelper {
    static let shared = KeychainHelper()

    private let service = "com.TablePro"
    private static let logger = Logger(subsystem: "com.TablePro", category: "KeychainHelper")
    private static let migrationKey = "com.TablePro.keychainMigratedToDataProtection"

    private init() {}

    // MARK: - Core Methods

    @discardableResult
    func save(key: String, data: Data) -> Bool {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        var status = SecItemAdd(addQuery as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecUseDataProtectionKeychain as String: true
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data
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
            kSecUseDataProtectionKeychain as String: true,
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

    func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true
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
}
