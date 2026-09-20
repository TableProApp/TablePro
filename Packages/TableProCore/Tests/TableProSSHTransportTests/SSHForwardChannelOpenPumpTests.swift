//
//  SSHForwardChannelOpenPumpTests.swift
//  TableProSSHTransportTests
//
//  Tests the deadline that bounds a forwarding channel open. Without it a stuck open
//  outlives the database driver's connect timeout, leaving an accepted socket that is
//  never written to and never closed, which the driver reports as a greeting-read
//  timeout with no stated cause (#1883).
//

import Foundation
@testable import TableProSSHTransport
import Testing

@Suite("SSHForwardChannelOpenPump")
struct SSHForwardChannelOpenPumpTests {
    @Test("An immediately available channel opens without polling")
    func opensWithoutPolling() throws {
        let channel = try #require(OpaquePointer(bitPattern: 0xDEAD_BEEF))
        let opener = FakeChannelOpener(attempts: [.opened(channel)])
        let polls = CountBox()

        let outcome = makePump(opener: opener, polls: polls).run()

        #expect(outcome == .opened(channel))
        #expect(opener.attemptCount == 1)
        #expect(polls.value == 0)
    }

    @Test("A non-EAGAIN failure returns immediately without polling")
    func failsFastWithoutPolling() {
        let opener = FakeChannelOpener(attempts: [.failed(code: 42, message: "channel open failure")])
        let polls = CountBox()

        let outcome = makePump(opener: opener, polls: polls).run()

        #expect(outcome == .failed(code: 42, message: "channel open failure"))
        #expect(opener.attemptCount == 1)
        #expect(polls.value == 0)
    }

    @Test("Retries through wouldBlock until the channel opens")
    func retriesUntilOpened() throws {
        let channel = try #require(OpaquePointer(bitPattern: 0xDEAD_BEEF))
        let opener = FakeChannelOpener(attempts: [
            .wouldBlock(.inbound),
            .wouldBlock(.outbound),
            .opened(channel),
        ])
        let polls = CountBox()

        let outcome = makePump(opener: opener, polls: polls).run()

        #expect(outcome == .opened(channel))
        #expect(opener.attemptCount == 3)
        #expect(polls.value == 2)
    }

    @Test("A never-ready open gives up at the deadline instead of retrying forever")
    func timesOutAtDeadline() {
        let opener = FakeChannelOpener(fallback: .wouldBlock(.inbound))
        let clock = SteppingClock(step: 1)

        let pump = SSHForwardChannelOpenPump(
            opener: opener,
            isActive: { true },
            deadline: clock.start.addingTimeInterval(5),
            pollForReadiness: { _ in true },
            now: clock.now
        )

        #expect(pump.run() == .timedOut)
        #expect(opener.attemptCount <= 6)
    }

    @Test("A directionless open cannot spin past the deadline")
    func directionlessOpenTimesOut() {
        let opener = FakeChannelOpener(fallback: .wouldBlock([]))
        let clock = SteppingClock(step: 1)

        let pump = SSHForwardChannelOpenPump(
            opener: opener,
            isActive: { true },
            deadline: clock.start.addingTimeInterval(3),
            pollForReadiness: { _ in true },
            now: clock.now
        )

        #expect(pump.run() == .timedOut)
    }

    @Test("A failed readiness wait gives up instead of retrying")
    func unreadyTransportTimesOut() {
        let opener = FakeChannelOpener(fallback: .wouldBlock(.inbound))

        let pump = SSHForwardChannelOpenPump(
            opener: opener,
            isActive: { true },
            deadline: Date().addingTimeInterval(60),
            pollForReadiness: { _ in false }
        )

        #expect(pump.run() == .timedOut)
        #expect(opener.attemptCount == 1)
    }

    @Test("Teardown during a retry cancels the open")
    func cancelsOnTeardown() {
        let opener = FakeChannelOpener(fallback: .wouldBlock(.inbound))
        let active = FlagBox(value: true)

        let pump = SSHForwardChannelOpenPump(
            opener: opener,
            isActive: { active.value },
            deadline: Date().addingTimeInterval(60),
            pollForReadiness: { _ in
                active.value = false
                return true
            }
        )

        #expect(pump.run() == .cancelled)
    }

    private func makePump(opener: FakeChannelOpener, polls: CountBox) -> SSHForwardChannelOpenPump {
        SSHForwardChannelOpenPump(
            opener: opener,
            isActive: { true },
            deadline: Date().addingTimeInterval(60),
            pollForReadiness: { _ in
                polls.value += 1
                return true
            }
        )
    }
}

@Suite("handleChannelOpenOutcome")
struct HandleChannelOpenOutcomeTests {
    @Test("An opened channel is relayed and the local socket stays open")
    func openedKeepsSocket() throws {
        let pair = SocketPair()
        defer { pair.close() }

        let channel = try #require(OpaquePointer(bitPattern: 0xFEED))
        var relayed: OpaquePointer?
        handleChannelOpenOutcome(.opened(channel), clientFD: pair.a) { relayed = $0 }

        #expect(relayed == channel)

        var byte: UInt8 = 7
        #expect(Darwin.send(pair.b, &byte, 1, 0) == 1)
    }

    @Test("A libssh2 failure closes the local socket so the client fails fast")
    func failedClosesSocket() {
        expectLocalSocketClosed(for: .failed(code: 42, message: "channel open failure"))
    }

    @Test("A channel open that hits the deadline closes the local socket")
    func timedOutClosesSocket() {
        expectLocalSocketClosed(for: .timedOut)
    }

    @Test("A cancelled channel open closes the local socket")
    func cancelledClosesSocket() {
        expectLocalSocketClosed(for: .cancelled)
    }

    private func expectLocalSocketClosed(for outcome: ChannelOpenOutcome) {
        let pair = SocketPair()
        defer { Darwin.close(pair.b) }

        var relayed = false
        handleChannelOpenOutcome(outcome, clientFD: pair.a) { _ in relayed = true }

        #expect(relayed == false)

        var byte: UInt8 = 0
        #expect(recv(pair.b, &byte, 1, 0) == 0)
    }
}

/// The mapping that carries a channel-open failure out to the app. Without it the reason is
/// computed and dropped, and the database driver reports a read timeout naming no cause (#1981).
@Suite("ChannelOpenOutcome.forwardFailure")
struct ChannelOpenOutcomeForwardFailureTests {
    private static let tcp = SSHForwardDestination.tcp(host: "db.internal", port: 3_306)
    private static let socket = SSHForwardDestination.unixSocket(path: "/var/run/mysqld/mysqld.sock")

    @Test("An opened channel has no failure to report")
    func openedHasNoFailure() throws {
        let channel = try #require(OpaquePointer(bitPattern: 0xBEEF))
        #expect(ChannelOpenOutcome.opened(channel).forwardFailure(destination: Self.tcp, deadlineSeconds: 6) == nil)
    }

    @Test("A cancelled open has no failure to report")
    func cancelledHasNoFailure() {
        #expect(ChannelOpenOutcome.cancelled.forwardFailure(destination: Self.tcp, deadlineSeconds: 6) == nil)
    }

    @Test("A refused TCP forward keeps the destination and the libssh2 detail")
    func failedTCPIsRefused() {
        let outcome = ChannelOpenOutcome.failed(code: -21, message: "channel open failure")

        #expect(
            outcome.forwardFailure(destination: Self.tcp, deadlineSeconds: 6)
                == .refused(destination: Self.tcp, detail: "channel open failure")
        )
    }

    @Test("A refused socket forward keeps the socket destination so the app can name the path")
    func failedSocketKeepsTheSocketDestination() {
        let outcome = ChannelOpenOutcome.failed(code: -21, message: "channel open failure")

        #expect(
            outcome.forwardFailure(destination: Self.socket, deadlineSeconds: 6)
                == .refused(destination: Self.socket, detail: "channel open failure")
        )
    }

    @Test("A timed-out open reports the destination and the budget that expired")
    func timedOutCarriesTheBudget() {
        #expect(
            ChannelOpenOutcome.timedOut.forwardFailure(destination: Self.tcp, deadlineSeconds: 6)
                == .timedOut(destination: Self.tcp, seconds: 6)
        )
    }

    @Test("A timed-out socket forward reports a timeout, not a refusal")
    func timedOutSocketReportsTimeout() {
        #expect(
            ChannelOpenOutcome.timedOut.forwardFailure(destination: Self.socket, deadlineSeconds: 10)
                == .timedOut(destination: Self.socket, seconds: 10)
        )
    }
}

private final class CountBox: @unchecked Sendable {
    var value = 0
}

private final class FlagBox: @unchecked Sendable {
    var value: Bool

    init(value: Bool) {
        self.value = value
    }
}

/// Returns timestamps that advance by a fixed step on every read, so a deadline is
/// reached deterministically without sleeping.
private final class SteppingClock: @unchecked Sendable {
    let start = Date(timeIntervalSince1970: 0)
    private let step: TimeInterval
    private var reads = 0

    init(step: TimeInterval) {
        self.step = step
    }

    func now() -> Date {
        defer { reads += 1 }
        return start.addingTimeInterval(step * Double(reads))
    }
}

private final class FakeChannelOpener: SSHForwardChannelOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [SSHForwardChannelAttempt]
    private let fallback: SSHForwardChannelAttempt
    private var madeAttempts = 0

    init(attempts: [SSHForwardChannelAttempt] = [], fallback: SSHForwardChannelAttempt = .wouldBlock(.inbound)) {
        self.attempts = attempts
        self.fallback = fallback
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return madeAttempts
    }

    func attemptOpen() -> SSHForwardChannelAttempt {
        lock.lock()
        defer { lock.unlock() }
        madeAttempts += 1
        return attempts.isEmpty ? fallback : attempts.removeFirst()
    }
}
