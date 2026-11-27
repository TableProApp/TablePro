//
//  DatabaseURLConnectionMatchTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro
@testable import TableProSSHConfig

@MainActor
struct DatabaseURLConnectionMatchTests {
    private let siteA = "/Users/me/Library/Application Support/Local/run/aaa/mysql/mysqld.sock"
    private let siteB = "/Users/me/Library/Application Support/Local/run/bbb/mysql/mysqld.sock"

    private func saved(socket: String? = nil, host: String = "localhost", port: Int = 3_306) -> DatabaseConnection {
        var connection = DatabaseConnection(
            name: "Site", host: host, port: port, database: "local", username: "root", type: .mysql
        )
        connection.localSocketPath = socket
        return connection
    }

    private func parsed(_ url: String) throws -> ParsedConnectionURL {
        try ConnectionURLParser.parse(url).get()
    }

    private func socketURL(_ path: String, scheme: String = "mysql", user: String = "root", database: String = "local") -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
        return "\(scheme)://\(user)@localhost/\(database)?socket=\(encoded)"
    }

    @Test("Two saved sites that differ only by socket each open from their own link")
    func socketPicksTheSite() throws {
        let connections = [saved(socket: siteA), saved(socket: siteB)]

        let forB = try parsed(socketURL(siteB))
        let matched = connections.filter { DatabaseURLConnectionMatch.matches(saved: $0, parsed: forB) }

        #expect(matched.count == 1)
        #expect(matched.first?.localSocketPath == siteB)
    }

    @Test("A socket link never opens a saved TCP connection to the same database")
    func socketLinkSkipsTCP() throws {
        #expect(!DatabaseURLConnectionMatch.matches(saved: saved(), parsed: try parsed(socketURL(siteA))))
    }

    @Test("A TCP link never opens a saved socket connection")
    func tcpLinkSkipsSocket() throws {
        let link = try parsed("mysql://root@localhost/local")
        #expect(!DatabaseURLConnectionMatch.matches(saved: saved(socket: siteA), parsed: link))
        #expect(DatabaseURLConnectionMatch.matches(saved: saved(), parsed: link))
    }

    @Test("A saved socket connection matches whatever its hidden host and port say")
    func socketIgnoresHiddenHost() throws {
        let connection = saved(socket: siteA, host: "db.internal", port: 3_307)
        #expect(DatabaseURLConnectionMatch.matches(saved: connection, parsed: try parsed(socketURL(siteA))))
    }

    @Test("Type, database and user still have to agree on a socket link")
    func socketStillComparesTheRest() throws {
        let connection = saved(socket: siteA)
        let otherDatabase = try parsed(socketURL(siteA, database: "other"))
        let otherUser = try parsed(socketURL(siteA, user: "admin"))
        let mariadb = try parsed(socketURL(siteA, scheme: "mariadb"))

        #expect(!DatabaseURLConnectionMatch.matches(saved: connection, parsed: otherDatabase))
        #expect(!DatabaseURLConnectionMatch.matches(saved: connection, parsed: otherUser))
        #expect(!DatabaseURLConnectionMatch.matches(saved: connection, parsed: mariadb))
    }

    @Test("A TCP link still matches on host and an explicit port")
    func tcpMatchesHostAndPort() throws {
        let connection = saved(host: "db.example.com", port: 3_307)
        #expect(DatabaseURLConnectionMatch.matches(saved: connection, parsed: try parsed("mysql://root@db.example.com:3307/local")))
        #expect(DatabaseURLConnectionMatch.matches(saved: connection, parsed: try parsed("mysql://root@db.example.com/local")))
        #expect(!DatabaseURLConnectionMatch.matches(saved: connection, parsed: try parsed("mysql://root@db.example.com:3308/local")))
        #expect(!DatabaseURLConnectionMatch.matches(saved: connection, parsed: try parsed("mysql://root@other.example.com/local")))
    }

    // The form saves a file connection with the default host and port, which a file URL never carries.
    @Test("A file link opens the saved connection to that file, whatever host the form stored")
    func fileLinkMatchesByPath() throws {
        let connection = DatabaseConnection(name: "Shop", database: "/path/to/shop.sqlite", type: .sqlite)
        #expect(connection.host == "localhost")

        #expect(DatabaseURLConnectionMatch.matches(
            saved: connection, parsed: try parsed("sqlite:///path/to/shop.sqlite?name=Elsewhere")
        ))
        #expect(!DatabaseURLConnectionMatch.matches(saved: connection, parsed: try parsed("sqlite:///path/to/other.sqlite")))
        #expect(!DatabaseURLConnectionMatch.matches(saved: connection, parsed: try parsed("duckdb:///path/to/shop.sqlite")))
    }

    // The local Database File of a Remote Database File row is a placeholder the form makes the user type.
    @Test("A file link never opens a saved connection that reads its file over SSH", arguments: [
        RemoteFileAccess.readOnlyCopy, .onServer
    ])
    func fileLinkSkipsRemoteFileRows(access: RemoteFileAccess) throws {
        var ssh = SSHConfiguration()
        ssh.enabled = true
        ssh.host = "prod-1"
        ssh.remoteFilePath = "/srv/app.db"
        ssh.remoteFileAccess = access
        let remote = DatabaseConnection(
            name: "Remote", database: "/path/to/shop.sqlite", type: .sqlite, sshTunnelMode: .inline(ssh)
        )
        #expect(!DatabaseURLConnectionMatch.matches(saved: remote, parsed: try parsed("sqlite:///path/to/shop.sqlite")))
    }

    @Test("A DuckDB file link matches the path in the DuckDB file field, and never a row in Remote mode")
    func duckDBFileLinkReadsItsField() throws {
        let link = try parsed("duckdb:///path/to/analytics.duckdb")
        let local = DatabaseConnection(
            name: "Local", database: "", type: .duckdb,
            additionalFields: ["duckdbMode": "local", "duckdbFilePath": "/path/to/analytics.duckdb"]
        )
        let legacy = DatabaseConnection(name: "Legacy", database: "/path/to/analytics.duckdb", type: .duckdb)
        let remote = DatabaseConnection(
            name: "Remote", database: "", type: .duckdb,
            additionalFields: ["duckdbMode": "remote", "duckdbHost": "quack.internal", "duckdbFilePath": "/path/to/analytics.duckdb"]
        )

        #expect(DatabaseURLConnectionMatch.matches(saved: local, parsed: link))
        #expect(DatabaseURLConnectionMatch.matches(saved: legacy, parsed: link))
        #expect(!DatabaseURLConnectionMatch.matches(saved: remote, parsed: link))
    }

    @Test("A DuckDB file link never opens a MotherDuck row through the file path it kept from Local File")
    func duckDBFileLinkSkipsAHiddenFileField() throws {
        let motherDuck = DatabaseConnection(
            name: "MotherDuck", database: "", type: .duckdb,
            additionalFields: [
                "duckdbMode": "motherduck",
                "duckdbMotherDuckDatabase": "my_db",
                "duckdbFilePath": "/path/to/analytics.duckdb"
            ]
        )
        #expect(!DatabaseURLConnectionMatch.matches(saved: motherDuck, parsed: try parsed("duckdb:///path/to/analytics.duckdb")))
    }

    private func quackRow(_ fields: [String: String] = [:]) -> DatabaseConnection {
        DatabaseConnection(
            name: "Quack", database: "", type: .duckdb,
            additionalFields: [
                "duckdbMode": "remote",
                "duckdbHost": "quack.internal",
                "duckdbPort": "9500",
                "duckdbAlias": "analytics",
                "duckdbSSLMode": "verifyIdentity"
            ].merging(fields) { _, field in field }
        )
    }

    @Test("A quack link opens the saved Quack row with its server and alias, at its port or none, whatever TLS it asks", arguments: [
        "quack://quack.internal:9500/analytics",
        "quack://quack.internal:9500/analytics?sslmode=disable",
        "quack://quack.internal/analytics"
    ])
    func quackLinkMatchesItsServerFields(url: String) throws {
        #expect(DatabaseURLConnectionMatch.matches(saved: quackRow(), parsed: try parsed(url)))
    }

    @Test("A quack link naming another server, port or alias opens no saved Quack row", arguments: [
        "quack://other.internal:9500/analytics",
        "quack://quack.internal:9501/analytics",
        "quack://quack.internal:9500/other",
        "quack://quack.internal:9500",
        "quack://quack.internal:9494/analytics"
    ])
    func quackLinkSkipsAnotherServer(url: String) throws {
        #expect(!DatabaseURLConnectionMatch.matches(saved: quackRow(), parsed: try parsed(url)))
    }

    @Test("A quack link that names the default port opens a Quack row on the default port")
    func quackLinkWithTheDefaultPortMatchesTheDefault() throws {
        let row = quackRow(["duckdbPort": ""])
        #expect(DatabaseURLConnectionMatch.matches(saved: row, parsed: try parsed("quack://quack.internal:9494/analytics")))
    }

    @Test("A quack link with no alias opens a Quack row that kept the default one")
    func quackLinkWithoutAliasMatchesTheDefault() throws {
        let row = quackRow(["duckdbAlias": ""])
        #expect(DatabaseURLConnectionMatch.matches(saved: row, parsed: try parsed("quack://quack.internal:9500")))
        #expect(DatabaseURLConnectionMatch.matches(saved: row, parsed: try parsed("quack://quack.internal:9500/remotedb")))
    }

    @Test("A quack link never opens a Local File or MotherDuck row, even one whose placeholder host is the link's")
    func quackLinkSkipsRowsThatDialNoServer() throws {
        let link = try parsed("quack://localhost")
        let local = DatabaseConnection(name: "Local", database: "", type: .duckdb, additionalFields: ["duckdbMode": "local"])
        let motherDuck = DatabaseConnection(name: "MotherDuck", database: "", type: .duckdb, additionalFields: ["duckdbMode": "motherduck"])
        #expect(local.host == "localhost")
        #expect(!DatabaseURLConnectionMatch.matches(saved: local, parsed: link))
        #expect(!DatabaseURLConnectionMatch.matches(saved: motherDuck, parsed: link))
    }
}
