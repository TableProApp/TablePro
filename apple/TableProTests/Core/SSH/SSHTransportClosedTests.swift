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
