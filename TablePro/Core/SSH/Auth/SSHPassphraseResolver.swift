//
//  SSHPassphraseResolver.swift
//  TablePro
//
//  Single source of truth for SSH key passphrase resolution.
//  Follows the native macOS chain: provided → macOS Keychain → user prompt.
//

import Foundation
import os

internal enum SSHPassphraseResolver {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHPassphraseResolver")

    struct Result {
        let passphrase: String
        let source: Source
        let saveToKeychain: Bool
    }

    enum Source {
        case provided       // From TablePro's own Keychain (connection config)
        case keychainSystem // From macOS SSH Keychain (ssh-add --apple-use-keychain)
        case userPrompt     // From interactive dialog
    }

    /// Resolve passphrase following the native macOS priority chain.
    ///
    /// 1. `provided` passphrase (from TablePro Keychain, passed by caller)
    /// 2. macOS SSH Keychain (where `ssh-add --apple-use-keychain` stores passphrases)
    /// 3. Interactive prompt (with "Save to Keychain" checkbox)
    ///
    /// - Parameters:
    ///   - keyPath: Absolute path to the SSH private key file
    ///   - provided: Passphrase from TablePro's own storage (may be nil)
    ///   - canPrompt: Whether to show an interactive dialog if all else fails
    /// - Returns: Resolved passphrase with its source, or nil if unavailable
    static func resolve(
        forKeyAt keyPath: String,
        provided: String?,
        canPrompt: Bool
    ) -> Result? {
        let expandedPath = SSHPathUtilities.expandTilde(keyPath)

        // 1. Use provided passphrase from TablePro's own Keychain
        if let provided, !provided.isEmpty {
            logger.debug("Using provided passphrase for \(expandedPath, privacy: .private)")
            return Result(passphrase: provided, source: .provided, saveToKeychain: false)
        }

        // 2. Check macOS SSH Keychain (ssh-add --apple-use-keychain format)
        if let systemPassphrase = SSHKeychainLookup.loadPassphrase(forKeyAt: expandedPath) {
            logger.debug("Found passphrase in macOS Keychain for \(expandedPath, privacy: .private)")
            return Result(passphrase: systemPassphrase, source: .keychainSystem, saveToKeychain: false)
        }

        // 3. Prompt the user interactively
        guard canPrompt else { return nil }

        let provider = PromptPassphraseProvider(keyPath: expandedPath)
        guard let promptResult = provider.providePassphrase() else { return nil }

        return Result(
            passphrase: promptResult.passphrase,
            source: .userPrompt,
            saveToKeychain: promptResult.saveToKeychain
        )
    }
}
