//
//  SSHTunnelErrorTests.swift
//  TableProTests
//
//  Tests for SSHTunnelError descriptions and isLocalPortBindFailure classification.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SSHTunnelError")
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

    @Test("SSHTunnelError.connectionTimeout has a localized description")
    func connectionTimeoutDescription() {
        let error = SSHTunnelError.connectionTimeout
        #expect(error.errorDescription != nil)
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
}
