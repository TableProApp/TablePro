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
