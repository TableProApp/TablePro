//
//  SSHTunnelErrorTests.swift
//  TableProTests
//
//  Tests for SSHTunnelError descriptions and isLocalPortBindFailure classification.
//

import Foundation
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
        let error = SSHTunnelError.authenticationFailed
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
}
