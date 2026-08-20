//
//  SSHForwardDestinationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SSH forward destination")
struct SSHForwardDestinationTests {
    @Test("A connection without a socket path forwards to its host and port")
    func defaultsToTCP() {
        let connection = DatabaseConnection(
            name: "tcp",
            host: "db.internal",
            port: 5_432,
            type: .postgresql
        )

        #expect(connection.sshForwardDestination == .tcp(host: "db.internal", port: 5_432))
        #expect(connection.sshForwardDestination.isUnixSocket == false)
    }

    @Test("A socket path takes precedence over host and port")
    func socketPathWins() {
        var connection = DatabaseConnection(
            name: "socket",
            host: "db.internal",
            port: 5_432,
            type: .postgresql
        )
        connection.sshForwardUnixSocketPath = "/var/run/postgresql/.s.PGSQL.5432"

        #expect(
            connection.sshForwardDestination
                == .unixSocket(path: "/var/run/postgresql/.s.PGSQL.5432")
        )
        #expect(connection.sshForwardDestination.isUnixSocket)
    }

    @Test("Clearing the socket path falls back to host and port")
    func clearingRestoresTCP() {
        var connection = DatabaseConnection(
            name: "socket",
            host: "db.internal",
            port: 5_432,
            type: .postgresql
        )
        connection.sshForwardUnixSocketPath = "/var/run/postgresql/.s.PGSQL.5432"
        connection.sshForwardUnixSocketPath = nil

        #expect(connection.sshForwardUnixSocketPath == nil)
        #expect(connection.sshForwardDestination == .tcp(host: "db.internal", port: 5_432))
    }

    @Test("The socket path survives a Codable round trip")
    func survivesCodableRoundTrip() throws {
        var connection = DatabaseConnection(
            name: "socket",
            host: "db.internal",
            port: 5_432,
            type: .postgresql
        )
        connection.sshForwardUnixSocketPath = "/var/run/postgresql/.s.PGSQL.5432"

        let data = try JSONEncoder().encode(connection)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)

        #expect(decoded.sshForwardDestination == .unixSocket(path: "/var/run/postgresql/.s.PGSQL.5432"))
    }

    @Test("Log description names the endpoint")
    func logDescription() {
        #expect(SSHForwardDestination.tcp(host: "db", port: 5_432).logDescription == "db:5432")
        #expect(SSHForwardDestination.unixSocket(path: "/tmp/pg.sock").logDescription == "/tmp/pg.sock")
    }
}
