//
//  HostKeyVerifier.swift
//  TablePro
//
//  Handles SSH host key verification with UI prompts.
//  Called during SSH tunnel establishment, after handshake but before auth.
//

import AppKit
import Foundation
import os

/// Handles host key verification with UI prompts
internal enum HostKeyVerifier {
    private static let logger = Logger(subsystem: "com.TablePro", category: "HostKeyVerifier")

    /// Verify the host key, prompting the user if needed.
    /// Uses `withCheckedContinuation` to await UI prompts without blocking the cooperative thread pool.
    /// - Parameters:
    ///   - keyData: The raw host key bytes from the SSH session
    ///   - keyType: The key type string (e.g. "ssh-rsa", "ssh-ed25519")
    ///   - hostname: The remote hostname
    ///   - port: The remote port
    /// - Throws: `SSHTunnelError.hostKeyVerificationFailed` if the user rejects the key
    static func verify(
        keyData: Data,
        keyType: String,
        hostname: String,
        port: Int
    ) async throws {
        let result = HostKeyStore.shared.verify(
            keyData: keyData,
            keyType: keyType,
            hostname: hostname,
            port: port
        )

        switch result {
        case .trusted:
            logger.debug("Host key trusted for [\(hostname)]:\(port)")
            return

        case .unknown(let fingerprint, let keyType):
            logger.info("Unknown host key for [\(hostname)]:\(port), prompting user")
            let accepted = await promptUnknownHost(
                hostname: hostname,
                port: port,
                fingerprint: fingerprint,
                keyType: keyType
            )
            guard accepted else {
                logger.info("User rejected unknown host key for [\(hostname)]:\(port)")
                throw SSHTunnelError.hostKeyVerificationFailed
            }
            HostKeyStore.shared.trust(
                hostname: hostname,
                port: port,
                key: keyData,
                keyType: keyType
            )

        case .mismatch(let expected, let actual):
            logger.warning("Host key mismatch for [\(hostname)]:\(port)")
            let accepted = await promptHostKeyMismatch(
                hostname: hostname,
                port: port,
                expected: expected,
                actual: actual
            )
            guard accepted else {
                logger.info("User rejected changed host key for [\(hostname)]:\(port)")
                throw SSHTunnelError.hostKeyVerificationFailed
            }
            HostKeyStore.shared.trust(
                hostname: hostname,
                port: port,
                key: keyData,
                keyType: keyType
            )
        }
    }

    // MARK: - UI Prompts

    /// Show a dialog asking the user whether to trust an unknown host.
    /// Suspends until the user responds, without blocking any thread.
    private static func promptUnknownHost(
        hostname: String,
        port: Int,
        fingerprint: String,
        keyType: String
    ) async -> Bool {
        let hostDisplay = "[\(hostname)]:\(port)"
        let title = String(localized: "Unknown SSH Host")
        let message = String(localized: """
            The authenticity of host '\(hostDisplay)' can't be established.

            \(keyType) key fingerprint is:
            \(fingerprint)

            Are you sure you want to continue connecting?
            """)

        return await MainActor.run {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "Trust"))
            alert.addButton(withTitle: String(localized: "Cancel"))

            let response = alert.runModal()
            return response == .alertFirstButtonReturn
        }
    }

    /// Show a warning dialog about a changed host key (potential MITM attack).
    /// Suspends until the user responds, without blocking any thread.
    private static func promptHostKeyMismatch(
        hostname: String,
        port: Int,
        expected: String,
        actual: String
    ) async -> Bool {
        let hostDisplay = "[\(hostname)]:\(port)"
        let title = String(localized: "SSH Host Key Changed")
        let message = String(localized: """
            WARNING: The host key for '\(hostDisplay)' has changed!

            This could mean someone is doing something malicious, or the server was reinstalled.

            Previous fingerprint: \(expected)
            Current fingerprint: \(actual)
            """)

        return await MainActor.run {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: String(localized: "Connect Anyway"))
            alert.addButton(withTitle: String(localized: "Disconnect"))

            // Make "Disconnect" the default button (Return key) instead of "Connect Anyway"
            alert.buttons[1].keyEquivalent = "\r"
            alert.buttons[0].keyEquivalent = ""

            let response = alert.runModal()
            return response == .alertFirstButtonReturn
        }
    }
}
