//
//  SSHTunnelManagerHealthTests.swift
//  TableProTests
//
//  Regression tests for SSHTunnelManager termination handlers (P2-1).
//  Validates health check configuration and process tree utilities.
//

import Foundation
@testable import TablePro
import Testing

@Suite("SSHTunnelManager Health")
struct SSHTunnelManagerHealthTests {
    // MARK: - Descendant Process Tree

    @Test("descendantProcessIds returns root when no children exist")
    func descendantProcessIdsRootOnly() {
        let result = SSHTunnelManager.descendantProcessIds(
            rootProcessId: 42,
            parentProcessIds: [100: 200, 300: 400]
        )
        #expect(result == [42])
    }

    @Test("descendantProcessIds finds deeply nested children")
    func descendantProcessIdsDeeplyNested() {
        let result = SSHTunnelManager.descendantProcessIds(
            rootProcessId: 1,
            parentProcessIds: [2: 1, 3: 2, 4: 3, 5: 4]
        )
        #expect(result == [1, 2, 3, 4, 5])
    }

    @Test("descendantProcessIds handles branching process tree")
    func descendantProcessIdsBranching() {
        let result = SSHTunnelManager.descendantProcessIds(
            rootProcessId: 1,
            parentProcessIds: [10: 1, 11: 1, 20: 10, 21: 10, 30: 11]
        )
        #expect(result == [1, 10, 11, 20, 21, 30])
    }

    @Test("descendantProcessIds with empty parent map returns root only")
    func descendantProcessIdsEmptyMap() {
        let result = SSHTunnelManager.descendantProcessIds(
            rootProcessId: 99,
            parentProcessIds: [:]
        )
        #expect(result == [99])
    }

    @Test("descendantProcessIds is idempotent across multiple calls")
    func descendantProcessIdsIdempotent() {
        let parentMap: [Int32: Int32] = [2: 1, 3: 1, 4: 2]

        let result1 = SSHTunnelManager.descendantProcessIds(rootProcessId: 1, parentProcessIds: parentMap)
        let result2 = SSHTunnelManager.descendantProcessIds(rootProcessId: 1, parentProcessIds: parentMap)

        #expect(result1 == result2)
    }

    // MARK: - Port Bind Failure Classification

    @Test("isLocalPortBindFailure detects all known bind failure patterns")
    func bindFailurePatterns() {
        #expect(SSHTunnelManager.isLocalPortBindFailure("Address already in use"))
        #expect(SSHTunnelManager.isLocalPortBindFailure("cannot listen to port: 60000"))
        #expect(SSHTunnelManager.isLocalPortBindFailure("Could not request local forwarding."))
        #expect(SSHTunnelManager.isLocalPortBindFailure("port forwarding failed for listen port 60123"))
    }

    @Test("isLocalPortBindFailure is case-insensitive")
    func bindFailureCaseInsensitive() {
        #expect(SSHTunnelManager.isLocalPortBindFailure("ADDRESS ALREADY IN USE"))
        #expect(SSHTunnelManager.isLocalPortBindFailure("Cannot Listen To Port"))
    }

    @Test("isLocalPortBindFailure returns false for unrelated SSH errors")
    func nonBindFailures() {
        #expect(!SSHTunnelManager.isLocalPortBindFailure("Permission denied"))
        #expect(!SSHTunnelManager.isLocalPortBindFailure("Connection refused"))
        #expect(!SSHTunnelManager.isLocalPortBindFailure("Host key verification failed"))
        #expect(!SSHTunnelManager.isLocalPortBindFailure(""))
    }

    // MARK: - SSHTunnelError Description

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

    @Test("SSHTunnelError.sshCommandNotFound has a localized description")
    func sshCommandNotFoundDescription() {
        let error = SSHTunnelError.sshCommandNotFound
        #expect(error.errorDescription != nil)
    }
}
