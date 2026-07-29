//
//  SSHForwardFailureRecorderTests.swift
//  TableProTests
//
//  Tests the seam that carries a forwarding failure out to the connect path. The tunnel
//  computed the reason and then dropped it, so the database driver reported a greeting-read
//  timeout naming no cause and the user had nothing to act on (#1981).
//

import Foundation
@testable import TablePro
import Testing

@Suite("SSHForwardFailureRecorder")
struct SSHForwardFailureRecorderTests {
    private static let tcp = SSHForwardDestination.tcp(host: "db.internal", port: 3_306)
    private static let socket = SSHForwardDestination.unixSocket(path: "/var/run/mysqld/mysqld.sock")

    @Test("Nothing is recorded before a forward fails")
    func startsEmpty() {
        #expect(SSHForwardFailureRecorder().consume() == nil)
    }

    @Test("An opened channel is not recorded as a failure")
    func openedIsNotRecorded() {
        let recorder = SSHForwardFailureRecorder()
        let channel = OpaquePointer(bitPattern: 0xBEEF)!

        recorder.record(.opened(channel), destination: Self.tcp, deadlineSeconds: 6)

        #expect(recorder.consume() == nil)
    }

    @Test("A cancelled open is not recorded as a failure")
    func cancelledIsNotRecorded() {
        let recorder = SSHForwardFailureRecorder()

        recorder.record(.cancelled, destination: Self.tcp, deadlineSeconds: 6)

        #expect(recorder.consume() == nil)
    }

    @Test("A refused forward is recorded against its destination")
    func refusedIsRecorded() {
        let recorder = SSHForwardFailureRecorder()

        recorder.record(
            .failed(code: -21, message: "channel open failure"),
            destination: Self.tcp,
            deadlineSeconds: 6
        )

        #expect(
            recorder.consume() == .forwardRefused(
                destination: "db.internal:3306",
                detail: "channel open failure"
            )
        )
    }

    @Test("A refused socket forward keeps the socket-specific reason")
    func refusedSocketIsRecorded() {
        let recorder = SSHForwardFailureRecorder()

        recorder.record(
            .failed(code: -21, message: "channel open failure"),
            destination: Self.socket,
            deadlineSeconds: 6
        )

        #expect(
            recorder.consume() == .socketForwardingRefused(
                path: "/var/run/mysqld/mysqld.sock",
                detail: "channel open failure"
            )
        )
    }

    @Test("A timed-out open is recorded with the budget that expired")
    func timedOutIsRecorded() {
        let recorder = SSHForwardFailureRecorder()

        recorder.record(.timedOut, destination: Self.tcp, deadlineSeconds: 6)

        #expect(recorder.consume() == .forwardTimedOut(destination: "db.internal:3306", seconds: 6))
    }

    @Test("Consuming clears the reason so it cannot be blamed for a later failure")
    func consumeClearsTheReason() {
        let recorder = SSHForwardFailureRecorder()
        recorder.record(.timedOut, destination: Self.tcp, deadlineSeconds: 6)

        #expect(recorder.consume() != nil)
        #expect(recorder.consume() == nil)
    }

    @Test("A later successful open does not clear a reason nobody has read yet")
    func successDoesNotClearPendingFailure() {
        let recorder = SSHForwardFailureRecorder()
        let channel = OpaquePointer(bitPattern: 0xBEEF)!

        recorder.record(.timedOut, destination: Self.tcp, deadlineSeconds: 6)
        recorder.record(.opened(channel), destination: Self.tcp, deadlineSeconds: 6)

        #expect(recorder.consume() == .forwardTimedOut(destination: "db.internal:3306", seconds: 6))
    }

    @Test("The most recent failure replaces an older one")
    func latestFailureWins() {
        let recorder = SSHForwardFailureRecorder()

        recorder.record(.timedOut, destination: Self.tcp, deadlineSeconds: 6)
        recorder.record(
            .failed(code: -21, message: "channel open failure"),
            destination: Self.tcp,
            deadlineSeconds: 6
        )

        #expect(
            recorder.consume() == .forwardRefused(
                destination: "db.internal:3306",
                detail: "channel open failure"
            )
        )
    }
}
