//
//  DatabaseConnectionPostgreSQLSocketTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import TableProPluginKit
import TableProSSHConfig
import Testing

@MainActor
struct DatabaseConnectionPostgreSQLSocketTests {
    private func socketConnection(
        _ path: String = "/tmp",
        port: Int = 5_432,
        username: String = "dat",
        sslMode: SSLMode = .verifyIdentity
    ) -> DatabaseConnection {
        var connection = DatabaseConnection(
            name: "Local", host: "localhost", port: port, database: "app", username: username, type: .postgresql
        )
        connection.sslConfig = SSLConfiguration(mode: sslMode, caCertificatePath: "/etc/ca.pem")
        connection.additionalFields[MySQLLocalSocket.fieldKey] = path
        return connection
    }

    @Test("A PostgreSQL socket is the file its folder and port name")
    func socketFile() {
        #expect(socketConnection("/var/run/postgresql", port: 5_433).localSocketFile == "/var/run/postgresql/.s.PGSQL.5433")
        #expect(socketConnection("/tmp/.s.PGSQL.5434").localSocketFile == "/tmp/.s.PGSQL.5434")
        #expect(socketConnection().timeoutEndpointName == "/tmp/.s.PGSQL.5432")
        #expect(socketConnection().endpointDescription == "/tmp/.s.PGSQL.5432")
    }

    @Test("A MySQL socket stays the path it names")
    func mysqlSocketFile() {
        var mysql = DatabaseConnection(name: "Local", host: "localhost", port: 3_306, type: .mysql)
        mysql.additionalFields[MySQLLocalSocket.fieldKey] = "/tmp/mysql.sock"
        #expect(mysql.localSocketFile == "/tmp/mysql.sock")
        #expect(!mysql.localSocketSkipsTLS)
    }

    @Test("A socket connection signs in with no SSL, whatever the saved mode")
    func noTLSOverSocket() {
        let connection = socketConnection()
        #expect(connection.localSocketSkipsTLS)
        #expect(connection.transportSSLConfiguration == SSLConfiguration())

        var tunneled = connection
        tunneled.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "bastion.example.com"))
        #expect(!tunneled.localSocketSkipsTLS)
        #expect(tunneled.transportSSLConfiguration.mode == .verifyIdentity)
    }

    @Test("~/.pgpass is looked up by localhost for /tmp, by the folder otherwise, and with the port")
    func pgpassLookup() {
        let defaultFolder = ConnectionCredentialResolver.pgpassLookup(for: socketConnection("/tmp", port: 5_433), username: "dat")
        #expect(defaultFolder == PgpassLookup(host: "localhost", port: 5_433, database: "app", username: "dat"))

        let otherFolder = ConnectionCredentialResolver.pgpassLookup(
            for: socketConnection("/var/run/postgresql/.s.PGSQL.5434"),
            username: "dat"
        )
        #expect(otherFolder == PgpassLookup(host: "/var/run/postgresql", port: 5_434, database: "app", username: "dat"))
    }

    @Test("A blank user is looked up in ~/.pgpass as the login name, as libpq does")
    func pgpassBlankUser() {
        let lookup = ConnectionCredentialResolver.pgpassLookup(for: socketConnection(username: ""), username: "")
        #expect(lookup.username == NSUserName())

        let tcp = DatabaseConnection(name: "TCP", host: "", port: 5_432, database: "app", type: .postgresql)
        #expect(ConnectionCredentialResolver.pgpassLookup(for: tcp, username: "").host == "localhost")
    }

    @Test("Trust given to one socket does not cover another server in the same folder")
    func trustCoversOneSocketFile() {
        let first = ExternalConnectionTrustKey(connection: socketConnection("/tmp", port: 5_432), scopeName: nil)
        let second = ExternalConnectionTrustKey(connection: socketConnection("/tmp", port: 5_433), scopeName: nil)
        #expect(first != second)
        #expect(first.isLoopbackHost)
    }

    @Test("A share link carries the folder and the port, and imports back to the same socket")
    func shareLinkRoundTrip() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let link = try #require(
            ConnectionShareLink.deeplink(for: socketConnection("/var/run/postgresql", port: 5_433), exporter: library.exporter)
        )
        let items = URLComponents(string: link)?.queryItems ?? []
        #expect(items.first { $0.name == "socket" }?.value == "/var/run/postgresql")
        #expect(items.first { $0.name == "port" }?.value == "5433")

        guard case .success(.importConnection(let bundle)) = DeeplinkParser.parse(try #require(URL(string: link))) else {
            Issue.record("The link did not import"); return
        }
        let settings = try #require(bundle.connections.first?.settings)
        #expect(settings.additionalFields?[MySQLLocalSocket.fieldKey] == "/var/run/postgresql")
        #expect(settings.port == 5_433)
    }

    @Test("An import link naming the socket file imports its folder and port")
    func importLinkWithSocketFile() throws {
        var components = URLComponents()
        components.scheme = "tablepro"
        components.host = "import"
        components.queryItems = [
            URLQueryItem(name: "name", value: "Local"),
            URLQueryItem(name: "type", value: "PostgreSQL"),
            URLQueryItem(name: "socket", value: "/tmp/.s.PGSQL.5433")
        ]
        guard case .success(.importConnection(let bundle)) = DeeplinkParser.parse(try #require(components.url)) else {
            Issue.record("The link did not import"); return
        }
        let settings = try #require(bundle.connections.first?.settings)
        #expect(settings.additionalFields?[MySQLLocalSocket.fieldKey] == "/tmp")
        #expect(settings.port == 5_433)
        #expect(settings.host == "localhost")
    }
}
