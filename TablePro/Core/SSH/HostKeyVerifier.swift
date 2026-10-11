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
        port: Int,
        attempt: SSHConnectionAttempt? = nil
    ) async throws {
        let timeoutEndpoint = ConnectionTimeoutEndpoint.tunnel("\(hostname):\(port)")
        try attempt?.check(for: timeoutEndpoint)
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
            let accepted = try await promptUnknownHost(
                hostname: hostname,
                port: port,
                fingerprint: fingerprint,
                keyType: keyType,
                attempt: attempt,
                timeoutEndpoint: timeoutEndpoint
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
            let accepted = try await promptHostKeyMismatch(
                hostname: hostname,
                port: port,
                expected: expected,
                actual: actual,
                attempt: attempt,
                timeoutEndpoint: timeoutEndpoint
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

    @MainActor
    private static func promptUnknownHost(
        hostname: String,
        port: Int,
        fingerprint: String,
        keyType: String,
        attempt: SSHConnectionAttempt?,
        timeoutEndpoint: ConnectionTimeoutEndpoint
    ) async throws -> Bool {
        let hostDisplay = "[\(hostname)]:\(port)"
        let title = String(localized: "Unknown SSH Host")
        let message = String(
            format: String(localized: """
                The authenticity of host '%@' can't be established.

                %@ key fingerprint is:
                %@

                Are you sure you want to continue connecting?
                """),
            hostDisplay,
            keyType,
            fingerprint
        )

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        AlertHelper.addConfirmAndCancel(
            to: alert,
            confirmButton: String(localized: "Trust"),
            cancelButton: String(localized: "Cancel")
        )

        if let window = AlertHelper.resolveWindow(nil) {
            return try await runSheet(
                alert,
                on: window,
                attempt: attempt,
                timeoutEndpoint: timeoutEndpoint
            )
        }
        return try runModal(alert, attempt: attempt, timeoutEndpoint: timeoutEndpoint)
    }

    @MainActor
    private static func promptHostKeyMismatch(
        hostname: String,
        port: Int,
        expected: String,
        actual: String,
        attempt: SSHConnectionAttempt?,
        timeoutEndpoint: ConnectionTimeoutEndpoint
    ) async throws -> Bool {
        let hostDisplay = "[\(hostname)]:\(port)"
        let title = String(localized: "SSH Host Key Changed")
        let message = String(
            format: String(localized: """
                WARNING: The host key for '%@' has changed!

                This could mean someone is doing something malicious, or the server was reinstalled.

                Previous fingerprint: %@
                Current fingerprint: %@
                """),
            hostDisplay,
            expected,
            actual
        )

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        AlertHelper.addConfirmAndCancel(
            to: alert,
            confirmButton: String(localized: "Connect Anyway"),
            cancelButton: String(localized: "Disconnect")
        )

        if let window = AlertHelper.resolveWindow(nil) {
            return try await runSheet(
                alert,
                on: window,
                attempt: attempt,
                timeoutEndpoint: timeoutEndpoint
            )
        }
        return try runModal(alert, attempt: attempt, timeoutEndpoint: timeoutEndpoint)
    }

    @MainActor
    private static func runSheet(
        _ alert: NSAlert,
        on window: NSWindow,
        attempt: SSHConnectionAttempt?,
        timeoutEndpoint: ConnectionTimeoutEndpoint
    ) async throws -> Bool {
        let promptId = try attempt?.registerPrompt(for: timeoutEndpoint) {
            guard alert.window.sheetParent === window else { return }
            window.endSheet(alert.window, returnCode: .abort)
        }
        defer {
            if let promptId {
                attempt?.unregisterPrompt(promptId)
            }
        }

        let accepted = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
        try attempt?.check(for: timeoutEndpoint)
        return accepted
    }

    @MainActor
    private static func runModal(
        _ alert: NSAlert,
        attempt: SSHConnectionAttempt?,
        timeoutEndpoint: ConnectionTimeoutEndpoint
    ) throws -> Bool {
        let promptId = try attempt?.registerPrompt(for: timeoutEndpoint) {
            if NSApp.modalWindow === alert.window {
                NSApp.abortModal()
            }
            alert.window.orderOut(nil)
        }
        defer {
            if let promptId {
                attempt?.unregisterPrompt(promptId)
            }
        }

        let accepted = alert.runModal() == .alertFirstButtonReturn
        try attempt?.check(for: timeoutEndpoint)
        return accepted
    }
}
