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

    @Test("The snapshot lists every saved connection by match key and as its export reads, and the saved queries")
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
        #expect(
            snapshot.connections.first?.settings
                == library.exporter.portableSettings(for: existing, keepingLocalCredentials: false)
        )
        #expect(snapshot.savedQueries.map(\.name) == ["Locks"])
    }

    @Test("A file carrying the saved connection's own export is offered Replace, one naming other hosts is not")
    func replaceIsOfferedOnlyForTheSameDestination() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let existing = DatabaseConnection(
            name: "Production", host: "es.prod.internal", port: 9_200,
            username: "elastic", type: .elasticsearch
        )
        #expect(library.connections.addConnection(existing))
        let own = library.exporter.portableSettings(for: existing)
        var moved = own
        moved.additionalFields = ["esHosts": "es.attacker.example:9200"]
        let bundle = try ConnectionBundle(appVersion: "Tests", connections: [
            BundleConnection(ref: "c1", settings: own),
            BundleConnection(ref: "c2", settings: moved),
        ])

        let preview = ConnectionImportAnalyzer.analyze(
            CollectedImport(bundle: bundle, source: .file(name: "Tests.tablepro")),
            library: try await library.store.snapshot(),
            environment: ImportLibraryFixture.environment(registeredTypeIds: ["Elasticsearch"])
        )

        let resolutions = preview.connections.map { $0.resolutions }
        #expect(resolutions == [[.addCopy, .replace(existing.id)], [.addCopy]])
    }

    @Test("A file exported from a row that signs in with an AWS profile is still offered Replace over that row")
    func replaceIsOfferedForARowWithALocalCredential() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        var existing = DatabaseConnection(
            name: "Analytics", host: "db.example.com", port: 5_432,
            database: "orders", username: "app", type: .postgresql
        )
        existing.additionalFields = ["awsAuth": "profile", "awsProfileName": "prod", "awsRegion": "eu-west-1"]
        #expect(library.connections.addConnection(existing))
        let data = try await library.exporter.fileData(for: [existing], options: .connectionsOnly, passphrase: nil)

        let preview = ConnectionImportAnalyzer.analyze(
            CollectedImport(bundle: try ConnectionBundleCodec.decode(data), source: .file(name: "Analytics.tablepro")),
            library: try await library.store.snapshot(),
            environment: ImportLibraryFixture.environment()
        )

        #expect(preview.connections.map { $0.resolutions } == [[.addCopy, .replace(existing.id)]])
    }

    @Test("A saved socket connection matches its exported settings, not a TCP connection to the same database")
    func snapshotKeysSocketConnectionsBySocketPath() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        var saved = DatabaseConnection(
            name: "Local", host: "localhost", port: 3_306, database: "app", username: "root", type: .mysql
        )
        saved.additionalFields[MySQLLocalSocket.fieldKey] = "/tmp/mysql.sock"
        #expect(library.connections.addConnection(saved))

        let snapshot = try await library.store.snapshot()

        var exported = ExportableConnection(
            name: "Local", host: "localhost", port: 3_306, database: "app", username: "root", type: "MySQL"
        )
        let tcpKey = ConnectionMatchKey(exported)
        exported.additionalFields = [MySQLLocalSocket.fieldKey: "/tmp/mysql.sock"]
        let key = try #require(snapshot.connections.first?.matchKey)
        #expect(key == ConnectionMatchKey(exported))
        #expect(key != tcpKey)
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

    @Test("A file's secure values land in the Keychain only for the fields the type declares secure")
    func credentialsWriteOnlyDeclaredSecureFields() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let importedId = UUID()
        let credentials = ExportableCredentials(
            password: nil,
            sshPassword: nil,
            keyPassphrase: nil,
            sslClientKeyPassphrase: nil,
            totpSecret: nil,
            pluginSecureFields: [
                "awsSecretAccessKey": "s3cr3t",
                "connectionOptions": "-c search_path=attacker",
                "zzzFutureSecret": "planted",
            ]
        )

        let outcome = try await library.importDefaults(
            of: bundle(settings(), credentials: credentials),
            makeId: { importedId }
        )

        #expect(outcome.connectionsAdded == 1)
        #expect(library.connections.loadPluginSecureField(fieldId: "awsSecretAccessKey", for: importedId) == "s3cr3t")
        #expect(library.connections.loadPluginSecureField(fieldId: "connectionOptions", for: importedId) == nil)
        #expect(library.connections.loadPluginSecureField(fieldId: "zzzFutureSecret", for: importedId) == nil)
    }

    @Test("A service account key given as a path is never stored; an inline key is")
    func keyDocumentPathsAreNotStored() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let pathId = UUID()
        let inlineId = UUID()
        let path = "~/.config/gcloud/legacy_credentials/sa/adc.json"
        let inline = #"{"type":"service_account","client_email":"sa@corp.example"}"#

        let pathOutcome = try await library.importDefaults(
            of: bundle(Self.bigQuery(name: "Warehouse"), credentials: ExportableCredentials(
                password: nil, sshPassword: nil, keyPassphrase: nil, sslClientKeyPassphrase: nil, totpSecret: nil,
                pluginSecureFields: ["bqServiceAccountJson": path]
            )),
            registeredTypeIds: ["BigQuery"],
            makeId: { pathId }
        )
        let inlineOutcome = try await library.importDefaults(
            of: bundle(Self.bigQuery(name: "Reports"), credentials: ExportableCredentials(
                password: nil, sshPassword: nil, keyPassphrase: nil, sslClientKeyPassphrase: nil, totpSecret: nil,
                pluginSecureFields: ["bqServiceAccountJson": inline]
            )),
            registeredTypeIds: ["BigQuery"],
            makeId: { inlineId }
        )

        #expect(pathOutcome.connectionsAdded == 1)
        #expect(inlineOutcome.connectionsAdded == 1)
        #expect(library.connections.loadPluginSecureField(fieldId: "bqServiceAccountJson", for: pathId) == nil)
        #expect(library.connections.loadPluginSecureField(fieldId: "bqServiceAccountJson", for: inlineId) == inline)
    }

    private static func bigQuery(name: String) -> ExportableConnection {
        ExportableConnection(
            name: name,
            host: "",
            port: 0,
            database: name.lowercased(),
            username: "",
            type: "BigQuery",
            additionalFields: ["bqProjectId": "attacker-project"]
        )
    }

    @Test("A Keyspaces row keeps its AWS secret before the Cassandra plugin has loaded")
    func catalogSecretsAreStored() async throws {
        let library = try ImportLibraryFixture()
        defer { library.cleanUp() }
        let importedId = UUID()
        var keyspaces = settings(name: "Keyspaces", host: "cassandra.us-east-1.amazonaws.com")
        keyspaces.type = "Cassandra"

        let outcome = try await library.importDefaults(
            of: bundle(keyspaces, credentials: ExportableCredentials(
                password: nil, sshPassword: nil, keyPassphrase: nil, sslClientKeyPassphrase: nil, totpSecret: nil,
                pluginSecureFields: ["awsSecretAccessKey": "s3cr3t", "zzzFutureSecret": "planted"]
            )),
            registeredTypeIds: ["Cassandra"],
            makeId: { importedId }
        )

        #expect(outcome.connectionsAdded == 1)

        #expect(library.connections.loadPluginSecureField(fieldId: "awsSecretAccessKey", for: importedId) == "s3cr3t")
        #expect(library.connections.loadPluginSecureField(fieldId: "zzzFutureSecret", for: importedId) == nil)
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
