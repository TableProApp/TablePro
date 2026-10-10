//
//  MacImportLibraryStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import Testing

@MainActor
struct MacImportLibraryStoreTests {
    private func settings(name: String = "Orders", host: String = "db.example.com") -> ExportableConnection {
        ExportableConnection(
            name: name,
            host: host,
            port: 5_432,
            database: "orders",
            username: "app",
            type: DatabaseType.postgresql.rawValue
        )
    }

    private func bundle(
        _ settings: ExportableConnection,
        credentials: ExportableCredentials? = nil,
        profile: BundleCredentialProfile? = nil
    ) throws -> ConnectionBundle {
        try ConnectionBundle(
            appVersion: "Tests",
            connections: [BundleConnection(ref: "c1", settings: settings, credentialProfileRef: profile?.ref)],
            credentialProfiles: profile.map { [$0] } ?? [],
            credentials: credentials.map { ["c1": $0] } ?? [:]
        )
    }

    private func password(_ value: String) -> ExportableCredentials {
        ExportableCredentials(
            password: value,
            sshPassword: nil,
            keyPassphrase: nil,
            sslClientKeyPassphrase: nil,
            totpSecret: nil,
            pluginSecureFields: nil
        )
    }

    // MARK: - Snapshot

    @Test("The snapshot lists every saved connection by match key, and the saved queries")
    func snapshotListsConnectionsAndQueries() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let existing = DatabaseConnection(
            name: "Orders", host: "DB.example.com", port: 5_432,
            database: "orders", username: "App", type: .postgresql
        )
        #expect(library.connections.addConnection(existing))
        #expect(await library.favorites.addFavorite(SQLFavorite(name: "Locks", query: "select 1")))

        let snapshot = try await library.store.snapshot()

        #expect(snapshot.connections.map(\.id) == [existing.id])
        #expect(snapshot.connections.first?.matchKey == ConnectionMatchKey(settings()))
        #expect(snapshot.savedQueries.map(\.name) == ["Locks"])
    }

    @Test("An unreadable connections file refuses the import and stays byte for byte")
    func unreadableConnectionsRefuse() async throws {
        let library = try ImportLibraryFixture(damage: [.connections])
        defer { library.cleanUp() }
        let fileURL = library.directory.appendingPathComponent("connections.json")
        let store = library.store

        await #expect(throws: ImportStoreError.unreadable) {
            _ = try await store.snapshot()
        }
        #expect(try Data(contentsOf: fileURL) == Data("not json".utf8))
    }

    @Test("An unreadable group store refuses the import")
    func unreadableGroupsRefuse() async throws {
        let library = try ImportLibraryFixture(damage: [.groups])
        defer { library.cleanUp() }
        let store = library.store

        await #expect(throws: ImportStoreError.unreadable) {
            _ = try await store.snapshot()
        }
    }

    @Test("An unreadable tag store refuses the import")
    func unreadableTagsRefuse() async throws {
        let library = try ImportLibraryFixture(damage: [.tags])
        defer { library.cleanUp() }
        let store = library.store

        await #expect(throws: ImportStoreError.unreadable) {
            _ = try await store.snapshot()
        }
    }

    @Test("Unreadable credential profiles turn profile import off instead of refusing the file")
    func unreadableProfilesTurnProfilesOff() async throws {
        let library = try ImportLibraryFixture(damage: [.profiles])
        defer { library.cleanUp() }

        let inputs = try await library.store.analysisInputs(environment: ImportLibraryFixture.environment())

        #expect(!inputs.environment.rules.supportsCredentialProfiles)
        #expect(inputs.environment.rules.supportsSavedQueries)
    }

    @Test("Unreadable saved queries turn query import off instead of refusing the file")
    func unreadableFavoritesTurnQueriesOff() async throws {
        let library = try ImportLibraryFixture(damage: [.favorites])
        defer { library.cleanUp() }
        #expect(library.connections.addConnection(DatabaseConnection(name: "Orders", type: .postgresql)))

        let inputs = try await library.store.analysisInputs(environment: ImportLibraryFixture.environment())

        #expect(!inputs.environment.rules.supportsSavedQueries)
        #expect(inputs.environment.rules.supportsCredentialProfiles)
        #expect(inputs.library.savedQueries.isEmpty)
        #expect(inputs.library.connections.count == 1)
    }

    // MARK: - Writes

    @Test("Adds and replaces land in one save and keep their timeouts")
    func writeConnectionsAddsAndReplaces() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let existing = DatabaseConnection(name: "Existing", host: "old.example.com", port: 5_432, type: .postgresql)
        #expect(library.connections.addConnection(existing))

        var added = settings(name: "Fresh", host: "fresh.example.com")
        added.connectTimeoutSeconds = 600
        added.queryTimeoutSeconds = 45
        var replacement = settings(name: "Imported", host: "new.example.com")
        replacement.connectTimeoutSeconds = 12
        replacement.queryTimeoutSeconds = 0
        let addedId = UUID()
        let write = library.store.writeConnections([
            ResolvedConnection(planned: planned(added, id: addedId, write: .add), groupId: nil, tagIds: [], credentialProfileId: nil),
            ResolvedConnection(
                planned: planned(replacement, id: existing.id, write: .replace),
                groupId: nil,
                tagIds: [],
                credentialProfileId: nil
            )
        ])

        #expect(write == ConnectionImportWrite(added: [addedId], replaced: [existing.id]))
        library.connections.invalidateCache()
        let saved = library.connections.loadConnections()
        let replaced = try #require(saved.first { $0.id == existing.id })
        #expect(replaced.name == "Imported")
        #expect(replaced.host == "new.example.com")
        #expect(replaced.connectTimeoutSeconds == 12)
        #expect(replaced.queryTimeoutSeconds == 0)
        let fresh = try #require(saved.first { $0.id == addedId })
        #expect(fresh.connectTimeoutSeconds == 600)
        #expect(fresh.queryTimeoutSeconds == 45)
    }

    @Test("An import saves each connection's icon and drops a malformed one")
    func importKeepsIcons() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        var picked = settings(name: "Picked", host: "picked.example.com")
        picked.iconName = "server.rack"
        var junk = settings(name: "Junk", host: "junk.example.com")
        junk.iconName = "Server Rack!"
        let bundle = try ConnectionBundle(
            appVersion: "Tests",
            connections: [
                BundleConnection(ref: "c1", settings: picked),
                BundleConnection(ref: "c2", settings: junk)
            ]
        )

        let outcome = try await library.importDefaults(of: bundle)

        #expect(outcome.connectionsAdded == 2)
        library.connections.invalidateCache()
        let saved = library.connections.loadConnections()
        #expect(saved.first { $0.name == "Picked" }?.iconName == "server.rack")
        #expect(saved.first { $0.name == "Junk" }?.iconName == nil)
    }

    @Test("Credentials from the file land on the connection the import saved")
    func credentialsLandOnTheSavedConnection() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let importedId = UUID()

        let outcome = try await library.importDefaults(
            of: bundle(settings(), credentials: password("secret")),
            makeId: { importedId }
        )

        #expect(outcome.connectionsAdded == 1)
        #expect(outcome.failure == nil)
        #expect(library.connections.loadPassword(for: importedId) == "secret")
    }

    @Test("A connections file that cannot be written gets no Keychain item")
    func unwritableLibraryWritesNoKeychainItem() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        _ = library.connections.loadConnections()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: library.directory.path)
        let importedId = UUID()

        let outcome = try await library.importDefaults(
            of: bundle(settings(), credentials: password("secret")),
            makeId: { importedId }
        )

        #expect(outcome.failure == .connectionsNotSaved)
        #expect(outcome.connectionsAdded == 0)
        #expect(library.connections.loadPassword(for: importedId) == nil)
    }

    @Test("A bound SSH profile survives only when this Mac stores it")
    func sshProfileBindsOnlyWhenStored() throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let stored = SSHProfile(name: "Bastion", host: "bastion.example.com")
        #expect(library.sshProfiles.addProfile(stored))

        var known = settings(name: "Known")
        known.sshProfileId = stored.id.uuidString
        var unknown = settings(name: "Unknown", host: "other.example.com")
        unknown.sshProfileId = UUID().uuidString
        let knownId = UUID()
        let unknownId = UUID()
        _ = library.store.writeConnections([
            ResolvedConnection(planned: planned(known, id: knownId, write: .add), groupId: nil, tagIds: [], credentialProfileId: nil),
            ResolvedConnection(planned: planned(unknown, id: unknownId, write: .add), groupId: nil, tagIds: [], credentialProfileId: nil)
        ])

        library.connections.invalidateCache()
        #expect(library.connections.loadConnection(id: knownId)?.sshProfileId == stored.id)
        #expect(library.connections.loadConnection(id: unknownId)?.sshProfileId == nil)
    }

    // MARK: - Environment

    @Test("The Mac environment allows nested groups, saved queries and profiles, and names missing plugins")
    func macEnvironmentRules() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacImportEnvironment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PluginManager(
            userDefaults: try #require(UserDefaults(suiteName: "MacImportEnvironment.\(UUID().uuidString)")),
            builtInPluginsURL: nil,
            userPluginsDir: root.appendingPathComponent("Plugins", isDirectory: true)
        )

        let environment = MacImportEnvironment.make(pluginManager: manager)

        #expect(environment.rules == ImportRules(
            maximumGroupDepth: ConnectionGroup.maxNestingDepth,
            supportsSavedQueries: true,
            supportsCredentialProfiles: true
        ))
        #expect(environment.registeredTypeIds.contains(DatabaseType.postgresql.rawValue))
        #expect(environment.missingDriverNames["DynamoDB"] == PluginManager.registryDisplayName(of: DatabaseType(rawValue: "DynamoDB")))
    }

    private func planned(_ settings: ExportableConnection, id: UUID, write: PlannedConnection.Write) -> PlannedConnection {
        PlannedConnection(
            ref: "c1",
            id: id,
            write: write,
            settings: settings,
            groupPath: [],
            tagNames: [],
            credentialProfileRef: nil,
            credentials: nil
        )
    }
}
