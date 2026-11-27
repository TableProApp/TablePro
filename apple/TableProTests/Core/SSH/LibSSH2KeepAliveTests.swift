//
//  LibSSH2KeepAliveTests.swift
//  TableProTests
//
//  The keep-alive and the channel EOF build their packets on their own stack, and libssh2 refuses every other send
//  until the same frame finishes one that blocked (apple/scripts/probes/check-libssh2-keepalive-pending.sh).
//

import CLibSSH2
import Foundation
@testable import TablePro
import Testing

struct LibSSH2KeepAliveTests {
    @Test("A stack-built packet may go out on a socket with room and nothing else waiting to send")
    func readyWithRoom() throws {
        let fixture = try KeepAliveFixture()
        defer { fixture.close() }

        #expect(stackPacketReadiness(session: fixture.session, transportFD: fixture.local) == .ready)
    }

    @Test("A stack-built packet waits while the socket has no room for it")
    func waitsOnAFullSocket() throws {
        let fixture = try KeepAliveFixture()
        defer { fixture.close() }

        fixture.fillLocal()

        #expect(stackPacketReadiness(session: fixture.session, transportFD: fixture.local) == .socketFull)
        let outcome = LibSSH2KeepAlive.send(session: fixture.session, transportFD: fixture.local)
        #expect(!outcome.failed)
        #expect(outcome.secondsToNext == 1)
    }

    @Test("A closed transport fails the keep-alive at once")
    func failsOnAClosedTransport() throws {
        let fixture = try KeepAliveFixture()
        defer { fixture.close() }

        fixture.closePeer()

        #expect(stackPacketReadiness(session: fixture.session, transportFD: fixture.local) == .gone)
        #expect(LibSSH2KeepAlive.send(session: fixture.session, transportFD: fixture.local).failed)
    }
}

private final class KeepAliveFixture {
    struct SetupFailure: Error {}

    let session: OpaquePointer
    let local: Int32
    private var peer: Int32

    init() throws {
        _ = LibSSH2TunnelFactory.initialized
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw SetupFailure() }
        guard let session = tablepro_libssh2_session_init() else {
            Darwin.close(fds[0])
            Darwin.close(fds[1])
            throw SetupFailure()
        }
        self.session = session
        local = fds[0]
        peer = fds[1]
    }

    func fillLocal() {
        let flags = fcntl(local, F_GETFL, 0)
        _ = fcntl(local, F_SETFL, flags | O_NONBLOCK)
        var chunk = [UInt8](repeating: 0x46, count: 4_096)
        while Darwin.send(local, &chunk, chunk.count, 0) > 0 {}
    }

    func closePeer() {
        Darwin.close(peer)
        peer = -1
    }

    func close() {
        libssh2_session_free(session)
        Darwin.close(local)
        if peer >= 0 { Darwin.close(peer) }
    }
}
