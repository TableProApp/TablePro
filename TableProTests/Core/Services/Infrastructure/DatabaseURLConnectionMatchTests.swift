//
//  DatabaseURLConnectionMatchTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

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
}
