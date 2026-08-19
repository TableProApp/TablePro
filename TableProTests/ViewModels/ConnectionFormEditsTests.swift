//
//  ConnectionFormEditsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Connection form edits")
struct ConnectionFormEditsTests {
    private func edits(
        additionalFields: [String: String] = [:],
        ownedAdditionalFieldIDs: Set<String> = []
    ) -> ConnectionFormEdits {
        ConnectionFormEdits(
            name: "Edited",
            host: "db.example.com",
            port: 6_000,
            database: "edited_db",
            username: "edited_user",
            type: .postgresql,
            sshConfig: SSHConfiguration(),
            sslConfig: SSLConfiguration(),
            color: .blue,
            tagIds: [],
            groupId: nil,
            sshProfileId: nil,
            sshTunnelMode: .disabled,
            cloudflareTunnelMode: .disabled,
            cloudSQLProxyMode: .disabled,
            socksProxyMode: .disabled,
            safeModeLevel: .silent,
            aiPolicy: nil,
            aiRules: nil,
            externalAccess: .readOnly,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: false,
            additionalFields: additionalFields,
            ownedAdditionalFieldIDs: ownedAdditionalFieldIDs
        )
    }

    private func populatedConnection() -> DatabaseConnection {
        var connection = DatabaseConnection(
            id: UUID(),
            name: "Original",
            host: "127.0.0.1",
            port: 5_432,
            database: "original_db",
            username: "original_user",
            type: .mysql
        )
        connection.sortOrder = 42
        connection.isFavorite = true
        connection.isSample = true
        connection.aiAlwaysAllowedTools = ["run_query", "list_tables"]
        connection.passwordSource = .env(variable: "PGPASSWORD")
        return connection
    }

    @Test("Applying edits keeps every property the form does not own")
    func preservesUnownedProperties() {
        let original = populatedConnection()

        let result = edits().applied(to: original)

        #expect(result.id == original.id)
        #expect(result.sortOrder == 42)
        #expect(result.isFavorite)
        #expect(result.isSample)
        #expect(result.aiAlwaysAllowedTools == ["run_query", "list_tables"])
        #expect(result.passwordSource == .env(variable: "PGPASSWORD"))
    }

    @Test("Applying edits overwrites every property the form owns")
    func overwritesOwnedProperties() {
        let result = edits().applied(to: populatedConnection())

        #expect(result.name == "Edited")
        #expect(result.host == "db.example.com")
        #expect(result.port == 6_000)
        #expect(result.database == "edited_db")
        #expect(result.username == "edited_user")
        #expect(result.type == .postgresql)
        #expect(result.color == .blue)
    }

    @Test("An additional field the form does not own is carried over")
    func carriesUnownedAdditionalField() {
        var original = populatedConnection()
        original.additionalFields = ["oracleServiceName": "ORCLPDB1", "mongoHosts": "a:27017"]

        let result = edits(
            additionalFields: ["mongoHosts": "b:27017"],
            ownedAdditionalFieldIDs: ["mongoHosts"]
        ).applied(to: original)

        #expect(result.additionalFields["oracleServiceName"] == "ORCLPDB1")
        #expect(result.additionalFields["mongoHosts"] == "b:27017")
    }

    @Test("An owned additional field the form cleared is removed")
    func removesClearedOwnedField() {
        var original = populatedConnection()
        original.additionalFields = ["mssqlSchema": "sales", "preConnectScript": "SET x = 1"]

        let result = edits(
            additionalFields: ["mssqlSchema": "dbo"],
            ownedAdditionalFieldIDs: ["mssqlSchema", "preConnectScript"]
        ).applied(to: original)

        #expect(result.additionalFields["mssqlSchema"] == "dbo")
        #expect(result.additionalFields["preConnectScript"] == nil)
    }

    @Test("An owned field is removed even when the form supplies no value for it")
    func removesOwnedFieldWithNoValue() {
        var original = populatedConnection()
        original.additionalFields = ["redisDatabase": "3"]

        let result = edits(
            additionalFields: [:],
            ownedAdditionalFieldIDs: ["redisDatabase"]
        ).applied(to: original)

        #expect(result.additionalFields.isEmpty)
    }

    @Test("A field the form supplies lands even when it was not declared owned")
    func acceptsSuppliedFieldOutsideOwnedSet() {
        let result = edits(
            additionalFields: ["oracleServiceName": "FREEPDB1"],
            ownedAdditionalFieldIDs: []
        ).applied(to: populatedConnection())

        #expect(result.additionalFields["oracleServiceName"] == "FREEPDB1")
    }

    @Test("The app-managed field set covers the keys no plugin declares")
    func appManagedFieldSet() {
        #expect(ConnectionFormEdits.appManagedAdditionalFieldIDs.contains("preConnectScript"))
        #expect(ConnectionFormEdits.appManagedAdditionalFieldIDs.contains("promptForPassword"))
        #expect(
            ConnectionFormEdits.appManagedAdditionalFieldIDs
                .contains(DatabaseConnection.sshForwardUnixSocketPathKey)
        )
    }
}
