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
}
