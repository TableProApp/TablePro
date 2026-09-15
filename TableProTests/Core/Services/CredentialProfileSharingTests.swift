//
//  CredentialProfileSharingTests.swift
//  TableProTests
//

import Foundation
import TableProImport
import Testing

@testable import TablePro

/// A bundle travels between Macs, so a profile in one has to arrive as something the receiving Mac
/// can resolve. Names travel; ids and secrets do not.
@Suite("Credential profile sharing")
@MainActor
struct CredentialProfileSharingTests {
    @Test("A profile's password never reaches an export bundle")
    func exportCarriesNoPassword() throws {
        let profile = CredentialProfile(name: "Prod reader", username: "app", passwordMode: .stored)
        let exportable = ExportableCredentialProfile(
            name: profile.name,
            username: profile.username,
            passwordMode: "stored"
        )
        let envelope = ConnectionExportEnvelope(
            formatVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 0),
            appVersion: "test",
            connections: [],
            groups: nil,
            tags: nil,
            credentials: nil,
            credentialProfiles: [exportable]
        )

        let json = try String(decoding: JSONEncoder().encode(envelope), as: UTF8.self)
        #expect(json.contains("Prod reader"))
        #expect(!json.contains("password\":\"" ))
    }

    /// The import boundary. A bundle is written by someone else, so letting its profile name select
    /// one of this Mac's existing profiles would let a shared file decide which of the user's own
    /// credentials a connection signs in with, and send them to whatever host the file names.
    @Test("A bundle's profile name never binds a connection to a profile already on this Mac")
    func importNeverBindsToAnExistingLocalProfileByName() {
        let exportable = ExportableConnection(
            name: "Imported",
            host: "attacker.example.com",
            port: 5432,
            database: "db",
            username: "someone",
            type: "PostgreSQL",
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            credentialProfileName: "Prod reader",
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )

        /// Empty, which is what a profile that was already here looks like: only profiles the
        /// import itself created are ever offered to a connection.
        let connection = ConnectionExportService.buildDatabaseConnection(
            id: UUID(),
            from: exportable,
            name: "Imported",
            tagIdsByName: [:],
            groupIdsByName: [:],
            importedProfileIds: [:]
        )

        #expect(connection.credentialMode == .inline)
    }

    @Test("A connection does link to a profile the same import created")
    func importLinksToAProfileItCreated() {
        let createdId = UUID()
        let exportable = ExportableConnection(
            name: "Imported",
            host: "db.example.com",
            port: 5432,
            database: "db",
            username: "app",
            type: "PostgreSQL",
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            credentialProfileName: "Prod reader",
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )

        let connection = ConnectionExportService.buildDatabaseConnection(
            id: UUID(),
            from: exportable,
            name: "Imported",
            tagIdsByName: [:],
            groupIdsByName: [:],
            importedProfileIds: ["prod reader": createdId]
        )

        #expect(connection.credentialMode == .profile(id: createdId))
    }

    /// A shared bundle that carried a shell command would run it on a Mac that never agreed to it,
    /// which is why a source-backed profile exports as one that asks.
    @Test("A password source is never exportable")
    func exportReducesAPasswordSource() {
        #expect(ConnectionExportService.portableModeForTesting(.source(.command(shell: "echo owned"))) == "prompt")
        #expect(ConnectionExportService.portableModeForTesting(.stored) == "stored")
        #expect(ConnectionExportService.portableModeForTesting(.pgpass) == "pgpass")
        #expect(ConnectionExportService.portableModeForTesting(.prompt) == "prompt")
    }
}
