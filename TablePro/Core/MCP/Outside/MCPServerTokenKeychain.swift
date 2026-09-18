//
//  MCPServerTokenKeychain.swift
//  TablePro
//

import Foundation
import os
import Security

/// Where an outside MCP server's bearer token lives: this Mac's Keychain, and only this Mac's.
///
/// Not `KeychainHelper`. That one marks every item synchronizable whenever the user has connection
/// password sync turned on, which is right for a database password the user asked to carry between
/// their machines and wrong for this: a server reachable from one Mac is not necessarily reachable
/// from another, and a token that travelled would be a credential the user never chose to copy.
/// The items here are written `kSecAttrSynchronizable = false` and
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, the same shape the Google refresh token uses.
internal struct MCPServerTokenKeychain: KeychainStoring {
    internal static let service = "com.TablePro.MCPOutsideServers"

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "MCPServerTokenKeychain")

    private static let usesDataProtectionKeychain: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) != nil
    }()

    @discardableResult
    internal func writeString(_ value: String, forKey key: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(Self.query(forKey: key) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            Self.log(status: updateStatus, operation: "update")
            return false
        }
        var addQuery = Self.query(forKey: key)
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            Self.log(status: addStatus, operation: "add")
            return false
        }
        return true
    }

    internal func readStringResult(forKey key: String) -> KeychainStringResult {
        var query = Self.query(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let token = String(data: data, encoding: .utf8),
                  !token.isEmpty
            else { return .notFound }
            return .found(token)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            return .locked
        case errSecUserCanceled:
            return .userCancelled
        case errSecAuthFailed:
            return .authFailed
        default:
            Self.log(status: status, operation: "read")
            return .error(status)
        }
    }

    internal func delete(forKey key: String) {
        let status = SecItemDelete(Self.query(forKey: key) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Self.log(status: status, operation: "delete")
        }
    }

    private static func query(forKey key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false
        ]
        if usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private static func log(status: OSStatus, operation: String) {
        logger.error("Keychain \(operation, privacy: .public) failed with OSStatus \(status, privacy: .public)")
    }
}
