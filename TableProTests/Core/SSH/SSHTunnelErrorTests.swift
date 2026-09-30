//
//  SSHTunnelErrorTests.swift
//  TableProTests
//
//  Tests for SSHTunnelError descriptions and isLocalPortBindFailure classification.
//

import Foundation
import os
@testable import TablePro
import TableProPluginKit
import Testing

struct SSHTunnelErrorTests {
    // MARK: - Port Bind Failure Classification

    @Test("isLocalPortBindFailure detects 'already in use' pattern")
    func bindFailureAlreadyInUse() {
        #expect(SSHTunnelManager.isLocalPortBindFailure("Address already in use"))
    }

    @Test("isLocalPortBindFailure is case-insensitive")
    func bindFailureCaseInsensitive() {
        #expect(SSHTunnelManager.isLocalPortBindFailure("ADDRESS ALREADY IN USE"))
    }

    @Test("isLocalPortBindFailure returns false for unrelated SSH errors")
    func nonBindFailures() {
        #expect(!SSHTunnelManager.isLocalPortBindFailure("Permission denied"))
        #expect(!SSHTunnelManager.isLocalPortBindFailure("Connection refused"))
        #expect(!SSHTunnelManager.isLocalPortBindFailure("Host key verification failed"))
        #expect(!SSHTunnelManager.isLocalPortBindFailure(""))
    }

    // MARK: - Error Descriptions

    @Test("SSHTunnelError.noAvailablePort has a localized description")
    func noAvailablePortDescription() {
        let error = SSHTunnelError.noAvailablePort
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test("SSHTunnelError.authenticationFailed has a localized description")
    func authenticationFailedDescription() {
        let error = SSHTunnelError.authenticationFailed(reason: .generic)
        #expect(error.errorDescription != nil)
    }

    @Test("SSHTunnelError.tunnelAlreadyExists includes connection ID in description")
    func tunnelAlreadyExistsDescription() {
        let id = UUID()
        let error = SSHTunnelError.tunnelAlreadyExists(id)
        #expect(error.errorDescription?.contains(id.uuidString) == true)
    }

    @Test("A connection timeout names the SSH endpoint and configured budget")
    func connectionTimeoutDescription() {
        let error = ConnectionTimeoutError(
            endpoint: .tunnel("bastion.example:2222"),
            configuredSeconds: 17
        )

        #expect(error.errorDescription?.contains("bastion.example:2222") == true)
        #expect(error.errorDescription?.contains("17") == true)
    }

    @Test("SSHTunnelError.socketForwardingRefused names the socket and the sshd setting")
    func socketForwardingRefusedDescription() {
        let error = SSHTunnelError.socketForwardingRefused(
            path: "/var/run/postgresql/.s.PGSQL.5432",
            detail: "channel open failed"
        )

        #expect(error.errorDescription?.contains("/var/run/postgresql/.s.PGSQL.5432") == true)
        #expect(error.errorDescription?.contains("AllowStreamLocalForwarding") == true)
        #expect(error.errorDescription?.contains("channel open failed") == true)
    }

    @Test("SSHTunnelError.forwardRefused names the destination, the sshd setting, and the detail")
    func forwardRefusedDescription() {
        let error = SSHTunnelError.forwardRefused(
            destination: "db.internal:3306",
            detail: "channel open failure"
        )

        #expect(error.errorDescription?.contains("db.internal:3306") == true)
        #expect(error.errorDescription?.contains("AllowTcpForwarding") == true)
        #expect(error.errorDescription?.contains("channel open failure") == true)
    }

    @Test("SSHTunnelError.forwardRefused explains that the host resolves from the SSH server")
    func forwardRefusedExplainsResolutionSide() {
        let error = SSHTunnelError.forwardRefused(destination: "db.internal:3306", detail: "refused")

        #expect(error.errorDescription?.contains("127.0.0.1") == true)
        #expect(error.errorDescription?.contains("localhost") == true)
    }

    @Test("SSHTunnelError.forwardTimedOut names the destination and the seconds waited")
    func forwardTimedOutDescription() {
        let error = SSHTunnelError.forwardTimedOut(destination: "db.internal:3306", seconds: 6)

        #expect(error.errorDescription?.contains("db.internal:3306") == true)
        #expect(error.errorDescription?.contains("6") == true)
    }

    @Test("A missing SSH username is plain text that names the host")
    func usernameMissingDescription() {
        let description = SSHTunnelError.usernameMissing(host: "bastion.example").errorDescription ?? ""

        #expect(!description.contains("`"))
        #expect(description.contains("bastion.example"))
        #expect(description.contains("~/.ssh/config"))
    }

    @Test("A failed remote command is plain text that names the command")
    func remoteCommandFailedIsPlainText() {
        let description = SFTPError.remoteCommandFailed(
            command: "VACUUM INTO",
            status: 1,
            output: "disk I/O error"
        ).errorDescription ?? ""

        #expect(!description.contains("`"))
        #expect(description.contains("VACUUM INTO"))
        #expect(description.contains("disk I/O error"))
    }

    @Test("An expired SSH attempt interrupts its transport and keeps the bastion in the error")
    func expiredAttemptInterruptsTransport() {
        let deadline = ConnectionDeadline(configuredSeconds: 30, instant: .now)
        let endpoint = ConnectionTimeoutEndpoint.tunnel("jump.example:2200")
        let attempt = SSHConnectionAttempt(deadline: deadline, endpoint: endpoint)
        let interrupted = OSAllocatedUnfairLock(initialState: false)
        _ = attempt.registerTransportInterrupt { interrupted.withLock { $0 = true } }

        #expect(throws: ConnectionTimeoutError(endpoint: endpoint, configuredSeconds: 30)) {
            try attempt.prepare(for: endpoint)
        }
        #expect(interrupted.withLock { $0 })
    }

    @Test("Cancelling SSH authentication dismisses its active prompt")
    func cancellationDismissesPrompt() async throws {
        let deadline = ConnectionDeadline(configuredSeconds: 30)
        let endpoint = ConnectionTimeoutEndpoint.tunnel("jump.example:22")
        let attempt = SSHConnectionAttempt(deadline: deadline, endpoint: endpoint)
        let dismissed = OSAllocatedUnfairLock(initialState: false)
        let promptId = try attempt.registerPrompt(for: endpoint) {
            dismissed.withLock { $0 = true }
        }

        attempt.cancel()
        for _ in 0..<20 where !dismissed.withLock({ $0 }) {
            await Task.yield()
        }

        #expect(dismissed.withLock { $0 })
        #expect(throws: CancellationError.self) {
            try attempt.check(for: endpoint)
        }
        attempt.unregisterPrompt(promptId)
    }

    @Test("SFTP reports exact deadline expiry against the remote-file endpoint")
    func sftpBudgetPreservesEndpointAtExactExpiry() {
        let startedAt = ContinuousClock.now
        let deadline = ConnectionDeadline(configuredSeconds: 60, startedAt: startedAt)
        let endpoint = ConnectionTimeoutEndpoint.remoteFile("files.example:2222")
        let budget = SFTPConnectionBudget(deadline: deadline, endpoint: endpoint)

        #expect(throws: ConnectionTimeoutError(endpoint: endpoint, configuredSeconds: 60)) {
            try budget.check(at: deadline.instant)
        }
    }

    @Test("SFTP chunk cancellation wins while deadline budget remains")
    func sftpBudgetHonorsCancellation() throws {
        let startedAt = ContinuousClock.now
        let deadline = ConnectionDeadline(configuredSeconds: 60, startedAt: startedAt)
        let budget = SFTPConnectionBudget(
            deadline: deadline,
            endpoint: .remoteFile("files.example:22")
        )

        #expect(throws: SFTPError.cancelled) {
            try budget.check(at: startedAt, isCancelled: { true })
        }
        #expect(try budget.remainingMilliseconds(
            at: startedAt.advanced(by: .seconds(15))
        ) == 45_000)
    }
}
