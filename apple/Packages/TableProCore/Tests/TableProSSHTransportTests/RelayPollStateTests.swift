//
//  RelayPollStateTests.swift
//  TableProSSHTransportTests
//

import Foundation
@testable import TableProSSHTransport
import Testing

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

struct TransportRoomTests {
    @Test("A socket with free buffer has room")
    func roomWhenEmpty() {
        let pair = SocketPair()
        defer { pair.close() }

        #expect(transportRoom(pair.a) == .room)
    }

    @Test("A socket whose buffer is full has no room")
    func fullWhenFilled() {
        let pair = SocketPair()
        defer { pair.close() }

        let flags = fcntl(pair.a, F_GETFL, 0)
        _ = fcntl(pair.a, F_SETFL, flags | O_NONBLOCK)
        var chunk = [UInt8](repeating: 0x46, count: 4_096)
        while Darwin.send(pair.a, &chunk, chunk.count, 0) > 0 {}

        #expect(transportRoom(pair.a) == .full)
    }

    @Test("A socket whose peer closed is gone")
    func goneWhenPeerClosed() {
        let pair = SocketPair()
        defer { pair.close() }

        pair.closeB()

        #expect(transportRoom(pair.a) == .gone)
    }
}
