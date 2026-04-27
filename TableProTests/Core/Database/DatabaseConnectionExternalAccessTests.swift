//
//  DatabaseConnectionExternalAccessTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("DatabaseConnection externalAccess")
struct DatabaseConnectionExternalAccessTests {
    @Test("Default value is readOnly")
    func defaultValueIsReadOnly() {
        let connection = DatabaseConnection(name: "Test")
        #expect(connection.externalAccess == .readOnly)
    }

    @Test("Decoding legacy JSON without externalAccess defaults to readOnly")
    func decodeLegacyJSONDefaultsToReadOnly() throws {
        let json = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "name": "Legacy",
            "host": "localhost",
            "port": 3306,
            "database": "test",
            "username": "root",
            "type": "MySQL",
            "sshConfig": { "enabled": false, "host": "", "port": 22, "username": "", "authMethod": "password", "privateKeyPath": "" },
            "sslConfig": { "mode": "preferred" },
            "color": "None",
            "sshTunnelMode": { "kind": "disabled" },
            "safeModeLevel": "silent",
            "additionalFields": {},
            "sortOrder": 0,
            "localOnly": false
        }
        """
        let data = Data(json.utf8)
        let connection = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(connection.externalAccess == .readOnly)
    }

    @Test("Decoding JSON with explicit externalAccess preserves value")
    func decodeJSONWithExplicitValue() throws {
        let json = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "name": "Test",
            "host": "localhost",
            "port": 3306,
            "database": "",
            "username": "",
            "type": "MySQL",
            "sshConfig": { "enabled": false, "host": "", "port": 22, "username": "", "authMethod": "password", "privateKeyPath": "" },
            "sslConfig": { "mode": "preferred" },
            "color": "None",
            "sshTunnelMode": { "kind": "disabled" },
            "safeModeLevel": "silent",
            "externalAccess": "blocked",
            "additionalFields": {},
            "sortOrder": 0,
            "localOnly": false
        }
        """
        let data = Data(json.utf8)
        let connection = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(connection.externalAccess == .blocked)
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
