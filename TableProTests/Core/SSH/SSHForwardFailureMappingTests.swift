//
//  SSHForwardFailureMappingTests.swift
//  TableProTests
//
//  The seam between the shared transport and the app's own error vocabulary. The transport stops
//  at SSHForwardFailure because it has no strings catalog; the app turns each one into the
//  SSHTunnelError that names the sshd setting the user has to change (#1981).
//

import Foundation
import TableProSSHTransport
import Testing

@testable import TablePro

@Suite("SSHForwardFailure to SSHTunnelError")
struct SSHForwardFailureMappingTests {
    private static let tcp = SSHForwardDestination.tcp(host: "db.internal", port: 3_306)
    private static let socket = SSHForwardDestination.unixSocket(path: "/var/run/mysqld/mysqld.sock")

    @Test("A refused TCP forward names the destination and carries the libssh2 detail")
    func refusedTCP() {
        let failure = SSHForwardFailure.refused(destination: Self.tcp, detail: "channel open failure")

        #expect(
            failure.tunnelError == .forwardRefused(destination: "db.internal:3306", detail: "channel open failure")
        )
    }

    @Test("A refused socket forward keeps the socket-specific error and its path")
    func refusedSocket() {
        let failure = SSHForwardFailure.refused(destination: Self.socket, detail: "channel open failure")

        #expect(
            failure.tunnelError == .socketForwardingRefused(
                path: "/var/run/mysqld/mysqld.sock",
                detail: "channel open failure"
            )
        )
    }

    @Test("A timed-out open reports the destination and the budget that expired")
    func timedOutTCP() {
        let failure = SSHForwardFailure.timedOut(destination: Self.tcp, seconds: 6)

        #expect(failure.tunnelError == .forwardTimedOut(destination: "db.internal:3306", seconds: 6))
    }

    @Test("A timed-out socket forward reports a timeout, not a refusal")
    func timedOutSocket() {
        let failure = SSHForwardFailure.timedOut(destination: Self.socket, seconds: 10)

        #expect(failure.tunnelError == .forwardTimedOut(destination: "/var/run/mysqld/mysqld.sock", seconds: 10))
    }

    @Test("A recorded failure reaches the app already spelled as an sshd setting")
    func recorderCarriesTheReasonThrough() {
        let recorder = SSHForwardFailureRecorder()
        recorder.record(.timedOut, destination: Self.tcp, deadlineSeconds: 6)

        #expect(recorder.consume()?.tunnelError == .forwardTimedOut(destination: "db.internal:3306", seconds: 6))
        #expect(recorder.consume() == nil)
    }
}
