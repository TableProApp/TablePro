//
//  DatabaseConnectionUsernameTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Database Connection Username")
struct DatabaseConnectionUsernameTests {
    @Test("Username defaults to empty, never a fabricated account name")
    func usernameDefaultsToEmpty() {
        let connection = DatabaseConnection(name: "Local")
        #expect(connection.username.isEmpty)
    }

    @Test("Decoding a connection with no username key yields an empty username")
    func decodingWithoutUsernameKeyYieldsEmpty() throws {
        let json = """
        {
            "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
            "name": "No User",
            "host": "localhost",
            "port": 3306,
            "type": "MySQL"
        }
        """
        let data = try #require(json.data(using: .utf8))
        let connection = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(connection.username.isEmpty)
    }

    @Test("Decoding preserves an explicit username")
    func decodingPreservesExplicitUsername() throws {
        let json = """
        {
            "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3302",
            "name": "With User",
            "host": "localhost",
            "port": 3306,
            "username": "admin",
            "type": "MySQL"
        }
        """
        let data = try #require(json.data(using: .utf8))
        let connection = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(connection.username == "admin")
    }

    @Test("An empty username round-trips through encoding")
    func emptyUsernameRoundTrips() throws {
        let connection = DatabaseConnection(name: "Local", username: "")
        let data = try JSONEncoder().encode(connection)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(decoded.username.isEmpty)
    }
}
