//
//  ConnectionURLImportUsernameTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Connection URL Import Username")
@MainActor
struct ConnectionURLImportUsernameTests {
    private func parse(_ urlString: String) throws -> ParsedConnectionURL {
        guard case .success(let parsed) = ConnectionURLParser.parse(urlString) else {
            throw ConnectionURLParseError.invalidURL
        }
        return parsed
    }

    @Test("Importing a MySQL URL with no user info keeps the username empty")
    func mysqlURLWithoutUserKeepsUsernameEmpty() throws {
        let parsed = try parse("mysql://localhost:3306/shop")
        let connection = TransientConnectionFactory.build(from: parsed)
        #expect(connection.username.isEmpty)
    }

    @Test("Importing a PostgreSQL URL with no user info keeps the username empty")
    func postgresURLWithoutUserKeepsUsernameEmpty() throws {
        let parsed = try parse("postgresql://db.example.com:5432/analytics")
        let connection = TransientConnectionFactory.build(from: parsed)
        #expect(connection.username.isEmpty)
    }

    @Test("A URL with user info still imports that username")
    func urlWithUserInfoKeepsUsername() throws {
        let parsed = try parse("mysql://admin:secret@localhost:3306/shop")
        let connection = TransientConnectionFactory.build(from: parsed)
        #expect(connection.username == "admin")
    }

    @Test("An imported connection with no username exports a URL with no user info")
    func emptyUsernameRoundTripsThroughFormatter() throws {
        let parsed = try parse("mysql://localhost:3306/shop")
        let connection = TransientConnectionFactory.build(from: parsed)
        let url = ConnectionURLFormatter.format(connection, password: "", sshPassword: nil)
        #expect(!url.contains("@"))
        #expect(url.contains("localhost"))
    }
}
