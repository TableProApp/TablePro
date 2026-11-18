//
//  SSHForwardDestinationTests.swift
//  TableProSSHTransportTests
//

import Foundation
import Testing

@testable import TableProSSHTransport

@Suite("SSH forward destination")
struct SSHForwardDestinationTests {
    @Test("A TCP destination is not a unix socket")
    func tcpIsNotASocket() {
        #expect(SSHForwardDestination.tcp(host: "db.internal", port: 5_432).isUnixSocket == false)
    }

    @Test("A socket destination reports itself as one")
    func socketReportsItself() {
        #expect(SSHForwardDestination.unixSocket(path: "/tmp/pg.sock").isUnixSocket)
    }

    @Test("Log description names the endpoint")
    func logDescription() {
        #expect(SSHForwardDestination.tcp(host: "db", port: 5_432).logDescription == "db:5432")
        #expect(SSHForwardDestination.unixSocket(path: "/tmp/pg.sock").logDescription == "/tmp/pg.sock")
    }

    @Test("A TCP forward opens a direct-tcpip channel with host, port, origin host and origin port")
    func tcpChannelRequest() {
        let request = SSHForwardDestination.tcp(host: "db", port: 5_432)
            .channelRequest(originHost: "127.0.0.1", originPort: 40_000)

        #expect(request.channelType == "direct-tcpip")
        #expect(request.message == [0, 0, 0, 2] + Array("db".utf8) + [0, 0, 0x15, 0x38]
            + [0, 0, 0, 9] + Array("127.0.0.1".utf8) + [0, 0, 0x9C, 0x40])
    }

    @Test("A socket forward opens a streamlocal channel with the path and the reserved origin fields")
    func socketChannelRequest() {
        let request = SSHForwardDestination.unixSocket(path: "/tmp/pg.sock")
            .channelRequest(originHost: "127.0.0.1", originPort: 40_000)

        #expect(request.channelType == "direct-streamlocal@openssh.com")
        #expect(request.message == [0, 0, 0, 12] + Array("/tmp/pg.sock".utf8)
            + [0, 0, 0, 9] + Array("127.0.0.1".utf8) + [0, 0, 0x9C, 0x40])
    }

    @Test("A host name counts its bytes, not its characters")
    func channelRequestCountsBytes() {
        let request = SSHForwardDestination.tcp(host: "dữ", port: 1)
            .channelRequest(originHost: "", originPort: 0)

        #expect(Array(request.message.prefix(4)) == [0, 0, 0, 4])
    }

    @Test("A forward asks for a window wider than the 2 MiB libssh2 opens with")
    func receiveWindowIsWiderThanTheDefault() {
        #expect(SSHForwardChannelRequest.receiveWindowBytes == 32 * 1_024 * 1_024)
        #expect(SSHForwardChannelRequest.maximumPacketBytes == 32_768)
    }
}
