//
//  CredentialProfileSharingTests.swift
//  TableProTests
//

import Foundation
import TableProImport
import Testing

@testable import TablePro

@MainActor
struct CredentialProfileSharingTests {
    private func bundleNamingProfile(_ name: String) throws -> ConnectionBundle {
        try ConnectionBundle(
            appVersion: "Tests",
            connections: [
                BundleConnection(
                    ref: "c1",
                    settings: ExportableConnection(
                        name: "Imported",
                        host: "attacker.example.com",
                        port: 5_432,
                        database: "db",
                        username: "someone",
                        type: DatabaseType.postgresql.rawValue
                    ),
                    credentialProfileRef: "p1"
                )
            ],
            credentialProfiles: [
                BundleCredentialProfile(ref: "p1", name: name, username: "someone", passwordMode: .stored)
            ]
        )
    }

    @Test("A profile's password never reaches an export file")
    func exportCarriesNoPassword() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let profile = CredentialProfile(name: "Prod reader", username: "app", passwordMode: .stored)
        #expect(library.profiles.addProfile(profile))
        #expect(library.profiles.savePassword("hunter2", for: profile.id))
        var connection = DatabaseConnection(name: "Orders", host: "db.example.com", port: 5_432, type: .postgresql)
        connection.credentialMode = .profile(id: profile.id)

        let data = try await library.exporter.fileData(for: [connection], options: .connectionsOnly, passphrase: nil)

        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(json.contains("Prod reader"))
        #expect(!json.contains("hunter2"))
    }

    /// A bundle is written by someone else, so letting its profile name select one of this Mac's
    /// profiles would let a shared file send the user's own credentials to whatever host it names.
    @Test("A bundle's profile name never binds a connection to a profile already on this Mac")
    func importNeverBindsToAnExistingLocalProfileByName() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        #expect(library.profiles.addProfile(CredentialProfile(name: "Prod reader", username: "app")))
        let importedId = UUID()

        let outcome = try await library.importDefaults(of: bundleNamingProfile("prod reader"), makeId: { importedId })

        #expect(outcome.connectionsAdded == 1)
        #expect(library.connections.loadConnection(id: importedId)?.credentialMode == .inline)
        #expect(library.profiles.loadProfiles().map(\.name) == ["Prod reader"])
    }

    @Test("A connection does link to a profile the same import created")
    func importLinksToAProfileItCreated() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let importedId = UUID()

        let outcome = try await library.importDefaults(of: bundleNamingProfile("Prod reader"), makeId: { importedId })

        #expect(outcome.connectionsAdded == 1)
        let created = try #require(library.profiles.loadProfiles().first { $0.name == "Prod reader" })
        #expect(created.passwordMode == .prompt)
        #expect(library.connections.loadConnection(id: importedId)?.credentialMode == .profile(id: created.id))
    }

    /// A shared bundle that carried a shell command would run it on a Mac that never agreed to it.
    @Test("A password source is never exportable")
    func exportReducesAPasswordSource() {
        #expect(ConnectionBundleExporter.portablePasswordMode(.source(.command(shell: "echo owned"))) == .prompt)
        #expect(ConnectionBundleExporter.portablePasswordMode(.stored) == .stored)
        #expect(ConnectionBundleExporter.portablePasswordMode(.pgpass) == .pgpass)
        #expect(ConnectionBundleExporter.portablePasswordMode(.prompt) == .prompt)
    }
}
