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
    static let passwordSyncEnabledKey = "com.TablePro.keychainPasswordSyncEnabled"

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
}
