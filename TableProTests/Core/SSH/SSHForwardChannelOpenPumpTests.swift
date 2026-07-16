//
//  SSHForwardChannelOpenPumpTests.swift
//  TableProTests
//
//  Tests the deadline that bounds a forwarding channel open. Without it a stuck open
//  outlives the database driver's connect timeout, leaving an accepted socket that is
//  never written to and never closed, which the driver reports as a greeting-read
//  timeout with no stated cause (#1883).
//

import Foundation
@testable import TablePro
import Testing

@Suite("SSHForwardChannelOpenPump")
struct SSHForwardChannelOpenPumpTests {
    @Test("An immediately available channel opens without polling")
    func opensWithoutPolling() {
        let opener = FakeChannelOpener(attempts: [.opened(Self.fakeChannel)])
        let polls = CountBox()

        let outcome = makePump(opener: opener, polls: polls).run()

        #expect(outcome == .opened(Self.fakeChannel))
        #expect(opener.attemptCount == 1)
        #expect(polls.value == 0)
    }

    @Test("A non-EAGAIN failure returns immediately without polling")
    func failsFastWithoutPolling() {
        let opener = FakeChannelOpener(attempts: [.failed(42)])
        let polls = CountBox()

        let outcome = makePump(opener: opener, polls: polls).run()

        #expect(outcome == .failed(42))
        #expect(opener.attemptCount == 1)
        #expect(polls.value == 0)
    }

    @Test("Retries through wouldBlock until the channel opens")
    func retriesUntilOpened() {
        let opener = FakeChannelOpener(attempts: [
            .wouldBlock(.inbound),
            .wouldBlock(.outbound),
            .opened(Self.fakeChannel),
        ])
        let polls = CountBox()

        let outcome = makePump(opener: opener, polls: polls).run()

        #expect(outcome == .opened(Self.fakeChannel))
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

    private static let fakeChannel = OpaquePointer(bitPattern: 0xDEAD_BEEF)!
}

@Suite("handleChannelOpenOutcome")
struct HandleChannelOpenOutcomeTests {
    @Test("An opened channel is relayed and the local socket stays open")
    func openedKeepsSocket() {
        let pair = SocketPair()
        defer { pair.close() }

        let channel = OpaquePointer(bitPattern: 0xFEED)!
        var relayed: OpaquePointer?
        handleChannelOpenOutcome(.opened(channel), clientFD: pair.a) { relayed = $0 }

        #expect(relayed == channel)

        var byte: UInt8 = 7
        #expect(Darwin.send(pair.b, &byte, 1, 0) == 1)
    }

    @Test("A libssh2 failure closes the local socket so the client fails fast")
    func failedClosesSocket() {
        expectLocalSocketClosed(for: .failed(42))
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
