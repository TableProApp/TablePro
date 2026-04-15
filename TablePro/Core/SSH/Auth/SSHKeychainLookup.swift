//
//  SSHKeychainLookup.swift
//  TablePro
//
//  Queries the macOS system Keychain for SSH key passphrases stored by
//  `ssh-add --apple-use-keychain`. Uses the same Keychain item format
//  as the native OpenSSH tools.
//

import Foundation
import os
import Security

internal enum SSHKeychainLookup {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHKeychainLookup")

    /// Look up a passphrase stored by `ssh-add --apple-use-keychain` for the given key path.
    ///
    /// macOS stores SSH passphrases as `kSecClassGenericPassword` items with
    /// `kSecAttrLabel = "SSH: /absolute/path/to/key"`.
    static func loadPassphrase(forKeyAt absolutePath: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "SSH",
            kSecAttrAccount as String: absolutePath,
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

    /// Save a passphrase to the macOS Keychain in the same format as `ssh-add --apple-use-keychain`.
    static func savePassphrase(_ passphrase: String, forKeyAt absolutePath: String) {
        let label = "SSH: \(absolutePath)"
        guard let data = passphrase.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: label,
            kSecAttrService as String: "SSH",
            kSecAttrAccount as String: absolutePath,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "SSH",
                kSecAttrAccount as String: absolutePath
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
