//
//  ConnectionURLPostgreSQLSocketTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionURLPostgreSQLSocketTests {
    private func parsed(_ url: String) throws -> ParsedConnectionURL {
        try ConnectionURLParser.parse(url).get()
    }

    private func socketConnection(_ path: String, port: Int = 5_432, sslMode: SSLMode = .preferred) -> DatabaseConnection {
        DatabaseConnection(
            name: "", host: "db.internal", port: port, database: "app", username: "dat", type: .postgresql,
            sslConfig: SSLConfiguration(mode: sslMode),
            additionalFields: [MySQLLocalSocket.fieldKey: path]
        )
    }

    @Test(
        "libpq's socket forms name the directory",
        arguments: [
            "postgresql:///app?host=/var/run/postgresql",
            "postgresql:///app?host=%2Fvar%2Frun%2Fpostgresql",
            "postgresql://%2Fvar%2Frun%2Fpostgresql/app",
            "postgres://dat@localhost/app?host=/var/run/postgresql",
            "postgresql://dat@db.example.com/app?host=/var/run/postgresql"
        ]
    )
    func socketForms(_ url: String) throws {
        let parsed = try parsed(url)
        #expect(parsed.type == .postgresql)
        #expect(parsed.localSocketPath == "/var/run/postgresql")
        #expect(parsed.host == "localhost")
        #expect(parsed.database == "app")
        #expect(parsed.resolvedPort == 5_432)
        #expect(parsed.localSocketFile == "/var/run/postgresql/.s.PGSQL.5432")
    }

    @Test("The port picks the socket file, from the URL, the query or the file name")
    func socketPort() throws {
        #expect(try parsed("postgresql://dat@:5433/app?host=/tmp").resolvedPort == 5_433)
        #expect(try parsed("postgresql://%2Ftmp:5433/app").resolvedPort == 5_433)
        #expect(try parsed("postgresql:///app?host=/tmp&port=5434").resolvedPort == 5_434)
        let file = try parsed("postgresql:///app?host=/tmp/.s.PGSQL.5435")
        #expect(file.localSocketPath == "/tmp")
        #expect(file.resolvedPort == 5_435)
    }

    @Test("An empty query port means the default port, and a bad one refuses the URL, as libpq does")
    func queryPortPresence() throws {
        #expect(try parsed("postgresql://dat@localhost:5433/app?host=/tmp&port=").resolvedPort == 5_432)
        for url in ["postgresql://dat@localhost:5433/app?host=/tmp&port=bad", "postgresql:///app?host=/tmp&port=70000"] {
            guard case .failure(let error) = ConnectionURLParser.parse(url) else {
                Issue.record("Expected \(url) to fail"); continue
            }
            #expect(error == .invalidURL)
        }
    }

    @Test("An empty query host is not the URL's own host")
    func emptyQueryHost() {
        guard case .failure(let error) = ConnectionURLParser.parse("postgresql://dat@db.example.com/app?host=") else {
            Issue.record("Expected failure"); return
        }
        #expect(error == .missingHost)
    }

    @Test("A query host or port overrides the URL's own, as libpq does")
    func queryOverridesAuthority() throws {
        let parsed = try parsed("postgresql://dat@a.example.com:5433/app?host=b.example.com&port=6432")
        #expect(parsed.host == "b.example.com")
        #expect(parsed.resolvedPort == 6_432)
        #expect(parsed.localSocketPath == nil)
    }

    @Test("A plus in the directory stays a plus, since libpq only percent-decodes")
    func plusStaysLiteral() throws {
        #expect(try parsed("postgresql:///app?host=/tmp/a+b").localSocketPath == "/tmp/a+b")
        #expect(try parsed("postgresql:///app?host=/tmp/a%20b").localSocketPath == "/tmp/a b")
    }

    @Test("socket= is MySQL's spelling, which libpq does not read")
    func socketParameterIsIgnored() throws {
        let parsed = try parsed("postgresql://dat@localhost/app?socket=/tmp")
        #expect(parsed.localSocketPath == nil)
        #expect(parsed.host == "localhost")
    }

    @Test("A directory libpq would misread fails the URL")
    func badDirectoryFails() {
        let cases: [(String, PostgreSQLLocalSocket.PathIssue)] = [
            ("postgresql:///app?host=/tmp,/var/run/postgresql", .comma),
            ("postgresql:///app?host=/tmp%0Ax", .hiddenCharacter)
        ]
        for (url, issue) in cases {
            guard case .failure(let error) = ConnectionURLParser.parse(url) else {
                Issue.record("Expected \(url) to fail"); continue
            }
            #expect(error == .invalidPostgreSQLSocketPath(issue))
            #expect(error.errorDescription == issue.message)
        }
    }

    @Test("Redshift and CockroachDB keep their host")
    func otherPostgresEnginesKeepHost() throws {
        #expect(try parsed("redshift://u@cluster.example.com/dev?host=/tmp").localSocketPath == nil)
        #expect(try parsed("cockroachdb://u@node.example.com/db?host=/tmp").localSocketPath == nil)
    }

    @Test("A socket connection copies as localhost and libpq's host= form")
    func copiesAsHostParameter() {
        let url = ConnectionURLFormatter.format(socketConnection("/var/run/postgresql"), password: "pw", sshPassword: nil)
        #expect(url == "postgresql://dat:pw@localhost/app?host=/var/run/postgresql")

        let otherPort = ConnectionURLFormatter.format(socketConnection("/tmp", port: 5_433), password: nil, sshPassword: nil)
        #expect(otherPort == "postgresql://dat@localhost:5433/app?host=/tmp")
    }

    @Test("A socket file stored whole copies as its directory and port")
    func socketFileCopiesAsDirectory() {
        let url = ConnectionURLFormatter.format(socketConnection("/tmp/.s.PGSQL.5433"), password: nil, sshPassword: nil)
        #expect(url == "postgresql://dat@localhost:5433/app?host=/tmp")
    }

    @Test("sslmode is left out, since no sslmode encrypts a socket")
    func noSSLModeOnSocket() {
        let url = ConnectionURLFormatter.format(socketConnection("/tmp", sslMode: .verifyIdentity), password: nil, sshPassword: nil)
        #expect(!url.contains("sslmode"))
    }

    @Test(
        "A copied socket URL parses back to the same socket file",
        arguments: ["/tmp", "/var/run/postgresql", "/Users/me/Library/Application Support/Postgres/var-17", "/tmp/a+b&c=d"]
    )
    func roundTrip(_ directory: String) throws {
        for port in [5_432, 5_433] {
            let connection = socketConnection(directory, port: port)
            let url = ConnectionURLFormatter.format(connection, password: nil, sshPassword: nil)
            let parsed = try ConnectionURLParser.parse(url).get()
            #expect(parsed.localSocketPath == directory)
            #expect(parsed.resolvedPort == port)
            #expect(DatabaseURLConnectionMatch.matches(saved: connection, parsed: parsed))
        }
    }

    @Test("Two servers in one socket directory are told apart by port")
    func matchByPort() throws {
        let parsed = try parsed("postgresql://dat@localhost:5433/app?host=/tmp")
        #expect(DatabaseURLConnectionMatch.matches(saved: socketConnection("/tmp", port: 5_433), parsed: parsed))
        #expect(!DatabaseURLConnectionMatch.matches(saved: socketConnection("/tmp", port: 5_432), parsed: parsed))
        #expect(!DatabaseURLConnectionMatch.matches(saved: socketConnection("/var/run/postgresql", port: 5_433), parsed: parsed))
    }
}
