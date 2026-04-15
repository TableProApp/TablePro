//
//  SSHKeychainLookup.swift
//  TablePro
//
//  Queries the user's login Keychain for SSH key passphrases stored by
//  `ssh-add --apple-use-keychain`. Uses the same item format as the
//  native OpenSSH tools (service="OpenSSH", label="SSH: /path/to/key").
//
//  Confirmed via `strings /usr/bin/ssh-add`: "SSH: %@", "OpenSSH",
//  "com.apple.ssh.passphrases".
//
//  Uses kSecUseDataProtectionKeychain=false to query the legacy file-based
//  keychain (login.keychain-db) where macOS SSH stores passphrases, without
//  triggering the System keychain admin password prompt.
//

import Foundation
import os
import Security

internal enum SSHKeychainLookup {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHKeychainLookup")
    private static let keychainService = "OpenSSH"

    /// Look up a passphrase stored by `ssh-add --apple-use-keychain`.
    static func loadPassphrase(forKeyAt absolutePath: String) -> String? {
        let label = "SSH: \(absolutePath)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrLabel as String: label,
            kSecUseDataProtectionKeychain as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let passphrase = String(data: data, encoding: .utf8) else {
                return nil
            }
            logger.debug("Found SSH passphrase in macOS Keychain for \(absolutePath, privacy: .private)")
            return passphrase

        case errSecItemNotFound:
            return nil

        case errSecAuthFailed, errSecInteractionNotAllowed:
            logger.warning("Keychain access denied for SSH passphrase lookup (status \(status))")
            return nil

        default:
            logger.warning("Keychain query failed with status \(status)")
            return nil
        }
    }

    /// Save a passphrase in the same format as `ssh-add --apple-use-keychain`.
    static func savePassphrase(_ passphrase: String, forKeyAt absolutePath: String) {
        let label = "SSH: \(absolutePath)"
        guard let data = passphrase.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: label,
            kSecAttrService as String: keychainService,
            kSecUseDataProtectionKeychain as String: false,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrLabel as String: label,
                kSecUseDataProtectionKeychain as String: false
            ]
            let updateAttrs: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
            if updateStatus != errSecSuccess {
                logger.warning("Failed to update SSH passphrase in Keychain (status \(updateStatus))")
            }
        } else if status != errSecSuccess {
            logger.warning("Failed to save SSH passphrase to Keychain (status \(status))")
        }
    }
}
