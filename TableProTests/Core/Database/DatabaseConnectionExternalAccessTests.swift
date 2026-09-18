//
//  DatabaseConnectionExternalAccessTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("DatabaseConnection externalAccess")
struct DatabaseConnectionExternalAccessTests {
    @Test("Default value is readOnly")
    func defaultValueIsReadOnly() {
        let connection = DatabaseConnection(name: "Test")
        #expect(connection.externalAccess == .readOnly)
    }

    /// Both cases build their JSON by encoding a real connection and editing one key, rather than
    /// hand-writing a document. The hand-written fixture they replace had drifted three ways at
    /// once: it named the SSH tunnel's discriminator `kind` when the wire key has always been
    /// `mode`, gave `sslConfig` only one of its four keys, and omitted `agentSocketPath` entirely.
    /// None of those shapes was ever written by the app, so the test failed on its own scaffolding
    /// instead of on the property it exists to check. Encoding first means the fixture cannot
    /// describe a document the encoder would not produce.
    private func encodedConnection(_ connection: DatabaseConnection) throws -> [String: Any] {
        let data = try JSONEncoder().encode(connection)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decodeConnection(from object: [String: Any]) throws -> DatabaseConnection {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(DatabaseConnection.self, from: data)
    }

    @Test("Decoding legacy JSON without externalAccess defaults to readOnly")
    func decodeLegacyJSONDefaultsToReadOnly() throws {
        var object = try encodedConnection(DatabaseConnection(name: "Legacy"))
        object.removeValue(forKey: "externalAccess")

        #expect(try decodeConnection(from: object).externalAccess == .readOnly)
    }

    @Test("Decoding JSON with explicit externalAccess preserves value")
    func decodeJSONWithExplicitValue() throws {
        var object = try encodedConnection(DatabaseConnection(name: "Test"))
        object["externalAccess"] = ExternalAccessLevel.blocked.rawValue

        #expect(try decodeConnection(from: object).externalAccess == .blocked)
    }

    @Test("Encoding round-trips externalAccess")
    func encodeRoundTrip() throws {
        let original = DatabaseConnection(
            name: "Test",
            externalAccess: .readWrite
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(decoded.externalAccess == .readWrite)
    }

    @Test("All cases are CaseIterable")
    func allCasesIterable() {
        #expect(ExternalAccessLevel.allCases.count == 3)
        #expect(ExternalAccessLevel.allCases.contains(.blocked))
        #expect(ExternalAccessLevel.allCases.contains(.readOnly))
        #expect(ExternalAccessLevel.allCases.contains(.readWrite))
    }
}
