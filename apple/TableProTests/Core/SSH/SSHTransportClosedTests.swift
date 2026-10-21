//
//  SSHTransportClosedTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct SSHTransportClosedTests {
    @Test("A transport whose server hung up reads as closed")
    func hungUpPeerIsClosed() throws {
        let pair = SocketPair()
        defer { pair.close() }
        try #require(pair.a >= 0)

        pair.closeB()

        #expect(LibSSH2TunnelFactory.transportClosed(pair.a))
    }

    @Test("A transport the server reset reads as closed")
    func resetPeerIsClosed() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try #require(bind(listener, $0, length) == 0)
                try #require(listen(listener, 1) == 0)
                try #require(getsockname(listener, $0, &length) == 0)
            }
        }

        let client = socket(AF_INET, SOCK_STREAM, 0)
        try #require(client >= 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
        }
        try #require(connected == 0)
        let server = accept(listener, nil, nil)
        try #require(server >= 0)
        var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
        setsockopt(server, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        close(server)
        var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        _ = poll(&descriptor, 1, 1_000)

        #expect(LibSSH2TunnelFactory.transportClosed(client))
    }

    @Test("A live transport with nothing to read, or with bytes waiting, is not closed")
    func livePeerIsOpen() throws {
        let pair = SocketPair()
        defer { pair.close() }
        try #require(pair.a >= 0)

        #expect(!LibSSH2TunnelFactory.transportClosed(pair.a))

        var byte: UInt8 = 7
        #expect(send(pair.b, &byte, 1, 0) == 1)
        #expect(!LibSSH2TunnelFactory.transportClosed(pair.a))
    }
}
