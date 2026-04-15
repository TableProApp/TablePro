//
//  SSHPassphraseResolver.swift
//  TablePro
//
//  Resolves SSH key passphrases from non-interactive sources.
//  Chain: provided (TablePro Keychain) → macOS SSH Keychain.
//  Interactive prompting is handled by the caller (KeyFileAuthenticator)
//  after a first authentication attempt fails.
//

import Foundation
import os

internal enum SSHPassphraseResolver {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHPassphraseResolver")

    /// Resolve passphrase from non-interactive sources only.
    ///
    /// 1. `provided` passphrase (from TablePro Keychain, passed by caller)
    /// 2. macOS SSH Keychain (where `ssh-add --apple-use-keychain` stores passphrases)
    ///
    /// Returns nil if no passphrase is found — the caller should try auth
    /// with nil (for unencrypted keys) and prompt interactively if that fails.
    static func resolve(
        forKeyAt keyPath: String,
        provided: String?,
        useKeychain: Bool = true
    ) -> String? {
        let expandedPath = SSHPathUtilities.expandTilde(keyPath)

        // 1. Use provided passphrase from TablePro's own Keychain
        if let provided, !provided.isEmpty {
            logger.debug("Using provided passphrase for \(expandedPath, privacy: .private)")
            return provided
        }

        // 2. Check macOS SSH Keychain (ssh-add --apple-use-keychain format)
        if useKeychain,
           let systemPassphrase = SSHKeychainLookup.loadPassphrase(forKeyAt: expandedPath) {
            logger.debug("Found passphrase in macOS Keychain for \(expandedPath, privacy: .private)")
            return systemPassphrase
        }

        return nil
    }
}
