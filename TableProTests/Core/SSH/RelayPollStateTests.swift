//
//  RelayPollStateTests.swift
//  TableProTests
//
//  Tests for relayFDState, the poll revents classifier that decides whether a
//  relay fd is idle, readable, draining before teardown, or fatally errored.
//

import Foundation
@testable import TablePro
import Testing

@Suite("RelayPollState")
struct RelayPollStateTests {
    @Test("No events is idle")
    func idle() {
        #expect(relayFDState(0) == .idle)
    }

    @Test("POLLIN alone is readable")
    func readable() {
        #expect(relayFDState(Int16(POLLIN)) == .readable)
    }

    @Test("POLLHUP drains then stops")
    func hangup() {
        #expect(relayFDState(Int16(POLLHUP)) == .drainThenStop)
    }

    @Test("POLLIN with POLLHUP drains then stops")
    func hangupWithBufferedData() {
        #expect(relayFDState(Int16(POLLIN) | Int16(POLLHUP)) == .drainThenStop)
    }

    @Test("POLLERR is fatal")
    func error() {
        #expect(relayFDState(Int16(POLLERR)) == .stop)
    }

    @Test("POLLNVAL is fatal")
    func invalid() {
        #expect(relayFDState(Int16(POLLNVAL)) == .stop)
    }

    @Test("Fatal errors win over readable data")
    func errorWithData() {
        #expect(relayFDState(Int16(POLLIN) | Int16(POLLERR)) == .stop)
    }

    @Test("Fatal errors win over hangup")
    func errorWithHangup() {
        #expect(relayFDState(Int16(POLLHUP) | Int16(POLLERR)) == .stop)
    }
}

@Suite("transportPollOutcome")
struct TransportPollOutcomeTests {
    @Test("An expired wait is not readiness")
    func timeoutIsNotReady() {
        #expect(transportPollOutcome(revents: 0, requestedEvents: Int16(POLLIN)) == .timedOut)
    }

    @Test("The requested direction becoming ready is readiness")
    func requestedDirectionReady() {
        #expect(transportPollOutcome(revents: Int16(POLLIN), requestedEvents: Int16(POLLIN)) == .ready)
        #expect(transportPollOutcome(revents: Int16(POLLOUT), requestedEvents: Int16(POLLOUT)) == .ready)
    }

    @Test("Another direction becoming ready is not the requested one")
    func otherDirectionIsNotReady() {
        #expect(transportPollOutcome(revents: Int16(POLLIN), requestedEvents: Int16(POLLOUT)) == .timedOut)
    }

    @Test("Hangup and errors end the wait")
    func hangupEndsWait() {
        #expect(transportPollOutcome(revents: Int16(POLLHUP), requestedEvents: Int16(POLLOUT)) == .hangup)
        #expect(transportPollOutcome(revents: Int16(POLLERR), requestedEvents: Int16(POLLOUT)) == .hangup)
        #expect(transportPollOutcome(revents: Int16(POLLNVAL), requestedEvents: Int16(POLLOUT)) == .hangup)
    }

    @Test("Hangup wins over the requested direction")
    func hangupWinsOverReady() {
        #expect(transportPollOutcome(revents: Int16(POLLOUT) | Int16(POLLHUP), requestedEvents: Int16(POLLOUT)) == .hangup)
    }
}

@Suite("pollReady")
struct PollReadyTests {
    @Test("A directionless wait yields and retries instead of spinning")
    func directionlessYields() {
        let pair = SocketPair()
        defer { pair.close() }

        #expect(pollReady(fd: pair.a, directions: [], timeoutMs: 5_000))
    }

    @Test("Readable data satisfies an inbound wait")
    func inboundReady() {
        let pair = SocketPair()
        defer { pair.close() }

        var byte: UInt8 = 1
        _ = Darwin.send(pair.b, &byte, 1, 0)

        #expect(pollReady(fd: pair.a, directions: .inbound, timeoutMs: 1_000))
    }

    @Test("An inbound wait with no data expires")
    func inboundExpires() {
        let pair = SocketPair()
        defer { pair.close() }

        #expect(pollReady(fd: pair.a, directions: .inbound, timeoutMs: 50) == false)
    }
}
