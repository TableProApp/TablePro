//
//  DatabaseManagerTunnelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DatabaseManager tunnel rewrite")
@MainActor
struct DatabaseManagerTunnelTests {
    @Test("Tunneled connection rewrites the endpoint and keeps the password source")
    func tunnelPreservesPasswordSource() {
        var connection = DatabaseConnection(
            name: "tunneled",
            host: "db.internal",
            port: 5_432,
            type: .postgresql
        )
        connection.passwordSource = .env(variable: "DB_PASS")

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 61_234)

        #expect(tunneled.host == "127.0.0.1")
        #expect(tunneled.port == 61_234)
        #expect(tunneled.passwordSource == .env(variable: "DB_PASS"))
    }

    @Test("Tunneled MongoDB collapses the seed list and forces a direct connection")
    func tunnelForcesMongoDirectConnection() {
        let connection = DatabaseConnection(
            name: "mongo",
            host: "primary.internal",
            port: 27_017,
            type: .mongodb,
            additionalFields: ["mongoHosts": "primary.internal:27017,secondary.internal:27017"]
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.host == "127.0.0.1")
        #expect(tunneled.port == 62_000)
        #expect(tunneled.additionalFields["mongoHosts"] == nil)
        #expect(tunneled.additionalFields["mongoParam_directConnection"] == "true")
    }

    @Test("Tunneled MongoDB leaves SRV connections untouched")
    func tunnelLeavesMongoSrvUntouched() {
        let connection = DatabaseConnection(
            name: "atlas",
            host: "cluster0.example.com",
            port: 27_017,
            type: .mongodb,
            additionalFields: ["mongoHosts": "cluster0.example.com", "mongoUseSrv": "true"]
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.additionalFields["mongoHosts"] == "cluster0.example.com")
        #expect(tunneled.additionalFields["mongoParam_directConnection"] == nil)
    }

    @Test("Tunneled non-MongoDB connection gets no direct-connection override")
    func tunnelLeavesNonMongoUntouched() {
        let connection = DatabaseConnection(
            name: "pg",
            host: "db.internal",
            port: 5_432,
            type: .postgresql
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.additionalFields["mongoParam_directConnection"] == nil)
    }

    @Test("A socket forward drops TLS, which the destination cannot negotiate")
    func socketForwardDisablesTLS() {
        var connection = DatabaseConnection(
            name: "socket",
            host: "db.internal",
            port: 5_432,
            type: .postgresql,
            sslConfig: SSLConfiguration(mode: .required)
        )
        connection.sshForwardUnixSocketPath = "/var/run/postgresql/.s.PGSQL.5432"

        let tunneled = DatabaseManager.shared.tunneledConnection(
            from: connection,
            localPort: 62_000,
            forwardsToUnixSocket: true
        )

        #expect(tunneled.sslConfig.mode == .disabled)
    }

    @Test("A TCP forward keeps encryption on")
    func tcpForwardKeepsTLS() {
        let connection = DatabaseConnection(
            name: "pg",
            host: "db.internal",
            port: 5_432,
            type: .postgresql,
            sslConfig: SSLConfiguration(mode: .verifyIdentity)
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.sslConfig.mode == .required)
    }

    @Test("The socket path never reaches the driver")
    func socketPathIsStrippedFromDriverFields() {
        var connection = DatabaseConnection(
            name: "socket",
            host: "db.internal",
            port: 5_432,
            type: .postgresql
        )
        connection.sshForwardUnixSocketPath = "/var/run/postgresql/.s.PGSQL.5432"

        let tunneled = DatabaseManager.shared.tunneledConnection(
            from: connection,
            localPort: 62_000,
            forwardsToUnixSocket: true
        )

        #expect(tunneled.host == "127.0.0.1")
        #expect(tunneled.port == 62_000)
        #expect(tunneled.additionalFields[DatabaseConnection.sshForwardUnixSocketPathKey] == nil)
    }
}
