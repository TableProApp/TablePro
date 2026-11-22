//
//  ConnectionURLEnvironmentTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct ConnectionURLEnvironmentTests {
    private func connection(environment: ConnectionEnvironment?) -> DatabaseConnection {
        var connection = DatabaseConnection(
            name: "", host: "db.example.com", port: 5_432, database: "orders",
            username: "app", type: .postgresql, sslConfig: SSLConfiguration(mode: DatabaseType.postgresql.defaultSSLMode)
        )
        connection.tagIds = [UUID()]
        if let environment {
            connection.additionalFields[ConnectionEnvironment.fieldKey] = environment.rawValue
        }
        return connection
    }

    private func parse(_ urlString: String) throws -> ParsedConnectionURL {
        guard case .success(let parsed) = ConnectionURLParser.parse(urlString) else {
            throw ConnectionURLParseError.invalidURL
        }
        return parsed
    }

    @Test("Copy as URL names the connection's Environment, not its first tag")
    func formatterWritesTheEnvironment() throws {
        let url = ConnectionURLFormatter.format(connection(environment: .staging), password: nil, sshPassword: nil)

        #expect(url == "postgresql://app@db.example.com/orders?env=staging")
        #expect(try parse(url).environment == .staging)
    }

    @Test("A connection with no Environment writes no env parameter, whatever its tags")
    func formatterSkipsNoEnvironment() {
        let url = ConnectionURLFormatter.format(connection(environment: nil), password: nil, sshPassword: nil)

        #expect(!url.contains("env="))
    }

    @Test("An env parameter in a link sets the Environment and adds no tag")
    func linkSetsTheEnvironment() throws {
        let opened = TransientConnectionFactory.build(from: try parse("postgresql://db.example.com/orders?env=prod"))

        #expect(ConnectionEnvironment.stored(in: opened.additionalFields) == .production)
        #expect(opened.tagIds.isEmpty)
    }

    @Test("An env name that is no Environment leaves it unset")
    func linkIgnoresAnUnknownEnvironment() throws {
        let opened = TransientConnectionFactory.build(from: try parse("postgresql://db.example.com/orders?env=qa"))

        #expect(ConnectionEnvironment.stored(in: opened.additionalFields) == .none)
    }
}
