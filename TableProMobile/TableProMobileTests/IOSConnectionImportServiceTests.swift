import Foundation
import TableProConnectionLibrary
import TableProDatabase
import TableProImport
import TableProModels
import Testing

@testable import TableProMobile

@MainActor
@Suite("iOS connection import")
struct IOSConnectionImportServiceTests {
    private let fixture: AppStateFixture
    private let store = MockSecureStore()
    private let appState: AppState

    init() throws {
        fixture = try AppStateFixture()
        appState = fixture.makeState(syncEnabled: false, secureStore: store)
    }

    private func analyzed(_ data: Data) async throws -> ImportPreview {
        try await IOSConnectionImportService.preview(
            of: ConnectionBundleCodec.decode(data),
            fileName: "Tests.tablepro",
            appState: appState
        )
    }

    private func analyzed(_ bundle: ConnectionBundle) async throws -> ImportPreview {
        try await analyzed(ConnectionBundleCodec.encode(bundle))
    }

    @discardableResult
    private func apply(_ preview: ImportPreview, _ selection: ImportSelection? = nil) async -> ImportOutcome {
        let plan = ImportPlanner.plan(preview, selection: selection ?? .defaults(for: preview))
        return await IOSConnectionImportService.apply(plan, appState: appState, secureStore: store)
    }

    private func settings(
        name: String = "Orders",
        host: String = "db.example.com",
        ssh: ExportableSSHConfig? = nil,
        ssl: ExportableSSLConfig? = nil,
        safeModeLevel: String? = nil,
        connectTimeoutSeconds: Int? = nil,
        queryTimeoutSeconds: Int? = nil,
        additionalFields: [String: String]? = nil
    ) -> ExportableConnection {
        ExportableConnection(
            name: name,
            host: host,
            port: 5_432,
            database: "orders",
            username: "app",
            type: DatabaseType.postgresql.rawValue,
            sshConfig: ssh,
            sslConfig: ssl,
            safeModeLevel: safeModeLevel,
            connectTimeoutSeconds: connectTimeoutSeconds,
            queryTimeoutSeconds: queryTimeoutSeconds,
            additionalFields: additionalFields
        )
    }

    private func importedConnection(_ settings: ExportableConnection) async throws -> DatabaseConnection {
        let bundle = try ConnectionBundle(appVersion: "Tests", connections: [BundleConnection(ref: "c1", settings: settings)])
        let outcome = await apply(try await analyzed(bundle))
        #expect(outcome.connectionsAdded == 1)
        return try #require(appState.connections.first)
    }

    // MARK: - Rules

    @Test("recognizes every known type plus the variants a Mac export can carry")
    func recognizesVariantTypes() {
        let recognized = IOSConnectionImportService.recognizedTypeIds
        #expect(DatabaseType.allKnownTypes.allSatisfy { recognized.contains($0.rawValue) })
        #expect(recognized.isSuperset(of: ["CockroachDB", "ScyllaDB", "Turso"]))
        #expect(!recognized.contains("Vertica"))
    }

    @Test("iPhone imports nested groups to the library depth and no saved queries or credential profiles")
    func environmentRules() {
        let rules = IOSConnectionImportService.environment().rules
        #expect(rules.maximumGroupDepth == LibraryGroupGraph.maxNestingDepth)
        #expect(!rules.supportsSavedQueries)
        #expect(!rules.supportsCredentialProfiles)
    }

    // MARK: - Files

    @Test("A version 1 file imports with its group and tags")
    func versionOneFileImports() async throws {
        let json = """
        {
          "formatVersion": 1,
          "exportedAt": "2026-07-14T09:00:00Z",
          "appVersion": "0.57.0",
          "connections": [
            {
              "name": "Production", "host": "db.example.com", "port": 3306, "database": "app",
              "username": "deploy", "type": "MySQL", "groupName": "Backend", "tagName": "production"
            }
          ],
          "groups": [{ "name": "Backend", "color": "Blue" }],
          "tags": [{ "name": "production", "color": "Red" }]
        }
        """

        let outcome = await apply(try await analyzed(Data(json.utf8)))

        #expect(outcome.connectionsAdded == 1)
        let connection = try #require(appState.connections.first)
        let group = try #require(appState.group(for: connection.groupId))
        #expect(group.name == "Backend")
        #expect(group.color == .blue)
        #expect(group.parentId == nil)
        #expect(connection.tagIds.compactMap { appState.tag(for: $0)?.name } == ["production"])
    }

    @Test("Saved queries in a version 2 file are left out and the connection still imports")
    func savedQueriesAreIgnored() async throws {
        var builder = ConnectionBundleBuilder(appVersion: "Tests")
        builder.addConnection(settings(), ref: "c1")
        builder.addSavedQuery(
            name: "Daily active users",
            sql: "select 1",
            keyword: "dau",
            folderPath: [ConnectionBundleBuilder.FolderComponent(name: "Reports", connection: "c1")],
            connection: "c1"
        )
        builder.addSavedQuery(name: "Locks", sql: "select 2", keyword: nil, connection: nil)

        let preview = try await analyzed(try builder.build())
        #expect(preview.queries.isEmpty)
        #expect(preview.connections.map(\.savedQueryCount) == [0])

        let outcome = await apply(preview)
        #expect(outcome.connectionsAdded == 1)
        #expect(outcome.savedQueriesAdded == 0)
        #expect(outcome.savedQueriesNotImported == 0)
    }

    @Test("A nested group path imports as nested groups")
    func nestedGroupPathImports() async throws {
        var builder = ConnectionBundleBuilder(appVersion: "Tests")
        builder.addConnection(settings(), ref: "c1", groupPath: [
            ConnectionBundleBuilder.GroupComponent(name: "Client A", color: "Blue"),
            ConnectionBundleBuilder.GroupComponent(name: "Production")
        ])

        await apply(try await analyzed(try builder.build()))

        let connection = try #require(appState.connections.first)
        let leaf = try #require(appState.group(for: connection.groupId))
        let root = try #require(appState.group(for: leaf.parentId))
        #expect(leaf.name == "Production")
        #expect(root.name == "Client A")
        #expect(root.color == .blue)
        #expect(root.parentId == nil)
    }

    @Test("Groups with the same name under different parents stay apart")
    func sameNameGroupsStayApart() async throws {
        var builder = ConnectionBundleBuilder(appVersion: "Tests")
        builder.addConnection(settings(name: "A", host: "a.example.com"), ref: "c1", groupPath: [
            ConnectionBundleBuilder.GroupComponent(name: "Client A"),
            ConnectionBundleBuilder.GroupComponent(name: "Prod")
        ])
        builder.addConnection(settings(name: "B", host: "b.example.com"), ref: "c2", groupPath: [
            ConnectionBundleBuilder.GroupComponent(name: "Client B"),
            ConnectionBundleBuilder.GroupComponent(name: "Prod")
        ])

        await apply(try await analyzed(try builder.build()))

        let groupIds = Set(appState.connections.compactMap(\.groupId))
        #expect(groupIds.count == 2)
        #expect(appState.groups.filter { $0.name == "Prod" }.count == 2)
    }

    @Test("An existing group path is reused rather than created again")
    func existingGroupPathIsReused() async throws {
        let root = ConnectionGroup(name: "Client A")
        #expect(appState.addGroup(root).isSaved)
        var builder = ConnectionBundleBuilder(appVersion: "Tests")
        builder.addConnection(settings(), ref: "c1", groupPath: [
            ConnectionBundleBuilder.GroupComponent(name: "client a"),
            ConnectionBundleBuilder.GroupComponent(name: "Production")
        ])

        await apply(try await analyzed(try builder.build()))

        let connection = try #require(appState.connections.first)
        let leaf = try #require(appState.group(for: connection.groupId))
        #expect(leaf.parentId == root.id)
        #expect(appState.groups.count == 2)
    }

    @Test("Only the groups and tags of the selected connections are created")
    func onlyUsedGroupsAndTagsAreCreated() async throws {
        var builder = ConnectionBundleBuilder(appVersion: "Tests")
        builder.addConnection(
            settings(name: "Kept", host: "kept.example.com"),
            ref: "c1",
            groupPath: [ConnectionBundleBuilder.GroupComponent(name: "Kept Group")],
            tags: [BundleTag(name: "kept-tag")]
        )
        builder.addConnection(
            settings(name: "Skipped", host: "skipped.example.com"),
            ref: "c2",
            groupPath: [ConnectionBundleBuilder.GroupComponent(name: "Skipped Group")],
            tags: [BundleTag(name: "skipped-tag")]
        )
        let preview = try await analyzed(try builder.build())
        var selection = ImportSelection.defaults(for: preview)
        selection.setSelected(false, connection: "c2", in: preview)

        let outcome = await apply(preview, selection)

        #expect(outcome.connectionsAdded == 1)
        #expect(appState.groups.map(\.name) == ["Kept Group"])
        #expect(appState.tags.contains { $0.name == "kept-tag" })
        #expect(!appState.tags.contains { $0.name == "skipped-tag" })
    }

    // MARK: - Duplicates

    @Test("A duplicate offers As Copy and Replace, and no Keep Existing without saved queries")
    func duplicateOffersCopyAndReplace() async throws {
        let existing = DatabaseConnection(
            name: "Orders",
            type: .postgresql,
            host: "db.example.com",
            port: 5_432,
            username: "app",
            database: "orders"
        )
        #expect(appState.addConnection(existing))
        let bundle = try ConnectionBundle(appVersion: "Tests", connections: [BundleConnection(ref: "c1", settings: settings())])

        let rows = try await analyzed(bundle).connections
        let row = try #require(rows.first)

        #expect(row.duplicate?.id == existing.id)
        #expect(!row.isSelectedByDefault)
        #expect(row.resolutions == [.addCopy, .replace(existing.id)])
    }

    @Test("Two rows can never replace the same connection")
    func secondReplaceIsRefused() async throws {
        let existing = DatabaseConnection(
            name: "Orders",
            type: .postgresql,
            host: "db.example.com",
            port: 5_432,
            username: "app",
            database: "orders"
        )
        #expect(appState.addConnection(existing))
        let bundle = try ConnectionBundle(appVersion: "Tests", connections: [
            BundleConnection(ref: "c1", settings: settings(name: "First")),
            BundleConnection(ref: "c2", settings: settings(name: "Second"))
        ])
        let preview = try await analyzed(bundle)
        var selection = ImportSelection.defaults(for: preview)
        selection.setSelected(true, connection: "c1", in: preview)
        selection.setSelected(true, connection: "c2", in: preview)

        let firstReplace = selection.resolve("c1", as: .replace(existing.id), in: preview)
        let secondReplace = selection.resolve("c2", as: .replace(existing.id), in: preview)

        #expect(firstReplace)
        #expect(!secondReplace)

        let outcome = await apply(preview, selection)

        #expect(outcome.connectionsReplaced == 1)
        #expect(outcome.connectionsAdded == 1)
        #expect(appState.connections.first { $0.id == existing.id }?.name == "First")
        #expect(appState.connections.contains { $0.name == "Second (Imported)" })
    }

    @Test("Replacing a connection keeps its favorite flag and its pasted key, whatever tunnel the import brings")
    func replaceKeepsLocalState() async throws {
        var existing = DatabaseConnection(
            name: "Bastion",
            type: .postgresql,
            host: "db.example.com",
            port: 5_432,
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(host: "bastion.example.com", username: "deploy", authMethod: .privateKey)
        )
        existing.isFavorite = true
        #expect(appState.addConnection(existing))
        let keyAccount = ConnectionSecretKind.sshPrivateKey.account(for: existing.id)
        let incoming: [ExportableSSHConfig?] = [
            tunnel(authMethod: "privateKey"),
            tunnel(authMethod: "privateKey", keyPath: "~/.ssh/id_ed25519"),
            tunnel(authMethod: "password"),
            nil
        ]

        for ssh in incoming {
            store.seed(keyAccount, "PASTED KEY")
            var imported = settings(name: existing.name, host: existing.host, ssh: ssh)
            imported.database = ""
            imported.username = ""
            let bundle = try ConnectionBundle(appVersion: "Tests", connections: [BundleConnection(ref: "c1", settings: imported)])
            let preview = try await analyzed(bundle)
            var selection = ImportSelection.defaults(for: preview)
            selection.setSelected(true, connection: "c1", in: preview)
            let replaces = selection.resolve("c1", as: .replace(existing.id), in: preview)
            #expect(replaces)

            let outcome = await apply(preview, selection)
            #expect(outcome.connectionsReplaced == 1)

            #expect(try store.retrieve(forKey: keyAccount) == "PASTED KEY", "\(ssh?.authMethod ?? "no tunnel")")
            #expect(appState.connections.first { $0.id == existing.id }?.isFavorite == true)
        }
    }

    private func tunnel(authMethod: String, keyPath: String = "") -> ExportableSSHConfig {
        ExportableSSHConfig(
            enabled: true, host: "bastion.example.com", port: 22, username: "deploy",
            authMethod: authMethod, privateKeyPath: keyPath, agentSocketPath: "", jumpHosts: nil,
            totpMode: nil, totpAlgorithm: nil, totpDigits: nil, totpPeriod: nil
        )
    }

    @Test("A library that failed to load refuses the preview and leaves the file alone")
    func unreadableLibraryRefusesPreview() async throws {
        let failedFixture = try AppStateFixture()
        let unreadable = Data("{ not json".utf8)
        try unreadable.write(to: failedFixture.connectionsFile)
        let failed = failedFixture.makeState(syncEnabled: false, secureStore: store)
        let bundle = try ConnectionBundle(appVersion: "Tests", connections: [BundleConnection(ref: "c1", settings: settings())])

        await #expect(throws: ImportStoreError.unreadable) {
            try await IOSConnectionImportService.preview(of: bundle, fileName: "Tests.tablepro", appState: failed)
        }
        #expect(try Data(contentsOf: failedFixture.connectionsFile) == unreadable)
    }

    // MARK: - Credentials

    @Test("An encrypted file restores passwords for the connections it saved")
    func encryptedFileRestoresCredentials() async throws {
        var builder = ConnectionBundleBuilder(appVersion: "Tests")
        builder.addConnection(settings(), ref: "c1", credentials: ExportableCredentials(
            password: "pw0", sshPassword: "ssh0", keyPassphrase: "key0",
            sslClientKeyPassphrase: nil, totpSecret: nil, pluginSecureFields: nil
        ))
        let sealed = try await ConnectionBundleCodec.encode(try builder.build(), passphrase: "correct horse")
        let bundle = try await ConnectionBundleCodec.decode(sealed, passphrase: "correct horse")
        let preview = try await IOSConnectionImportService.preview(of: bundle, fileName: "Tests.tablepro", appState: appState)

        await apply(preview)

        let id = try #require(appState.connections.first?.id)
        #expect(try store.retrieve(forKey: ConnectionSecretKind.password.account(for: id)) == "pw0")
        #expect(try store.retrieve(forKey: ConnectionSecretKind.sshPassword.account(for: id)) == "ssh0")
        #expect(try store.retrieve(forKey: ConnectionSecretKind.keyPassphrase.account(for: id)) == "key0")
    }

    @Test("A connection the library refuses to save gets no Keychain item and is not counted")
    func unsavedConnectionGetsNoCredentials() async throws {
        var builder = ConnectionBundleBuilder(appVersion: "Tests")
        builder.addConnection(settings(), ref: "c1", credentials: ExportableCredentials(
            password: "pw0", sshPassword: nil, keyPassphrase: nil,
            sslClientKeyPassphrase: nil, totpSecret: nil, pluginSecureFields: nil
        ))
        let sealed = try await ConnectionBundleCodec.encode(try builder.build(), passphrase: "correct horse")
        let bundle = try await ConnectionBundleCodec.decode(sealed, passphrase: "correct horse")
        let preview = try await IOSConnectionImportService.preview(of: bundle, fileName: "Tests.tablepro", appState: appState)
        let plan = ImportPlanner.plan(preview, selection: .defaults(for: preview))
        let plannedId = try #require(plan.connections.first?.id)

        let failedFixture = try AppStateFixture()
        try Data("{ not json".utf8).write(to: failedFixture.connectionsFile)
        let failed = failedFixture.makeState(syncEnabled: false, secureStore: store)
        let outcome = await IOSConnectionImportService.apply(plan, appState: failed, secureStore: store)

        #expect(outcome.failure == .connectionsNotSaved)
        #expect(outcome.connectionsAdded == 0)
        #expect(try store.retrieve(forKey: ConnectionSecretKind.password.account(for: plannedId)) == nil)
    }

    // MARK: - SSL

    @Test("SSL modes from either app import as the closest iOS mode")
    func sslModeImports() async throws {
        let cases: [(mode: String, expected: SSLConfiguration.SSLMode)] = [
            ("Required", .require),
            ("Preferred", .require),
            ("Verify CA", .verifyCa),
            ("Verify Identity", .verifyFull),
            ("require", .require),
            ("verifyCa", .verifyCa),
            ("verifyFull", .verifyFull)
        ]
        for (index, entry) in cases.enumerated() {
            let host = "ssl-\(index).example.com"
            let bundle = try ConnectionBundle(appVersion: "Tests", connections: [
                BundleConnection(ref: "c1", settings: settings(host: host, ssl: ExportableSSLConfig(mode: entry.mode)))
            ])
            await apply(try await analyzed(bundle))

            let connection = try #require(appState.connections.first { $0.host == host })
            #expect(connection.sslEnabled, "\(entry.mode)")
            #expect(connection.sslConfiguration?.mode == entry.expected, "\(entry.mode)")
        }
    }

    @Test("An unknown SSL mode imports as required, never as off")
    func unknownSSLModeImportsRequired() async throws {
        let bundle = try ConnectionBundle(appVersion: "Tests", connections: [
            BundleConnection(ref: "c1", settings: settings(ssl: ExportableSSLConfig(mode: "strict-ish")))
        ])
        let preview = try await analyzed(bundle)
        #expect(preview.connections.first?.warnings.isEmpty == false)

        await apply(preview)

        let connection = try #require(appState.connections.first)
        #expect(connection.sslEnabled)
        #expect(connection.sslConfiguration?.mode == .require)
    }

    @Test("A disabled SSL mode imports with SSL off")
    func disabledSSLModeImportsOff() async throws {
        let connection = try await importedConnection(settings(ssl: ExportableSSLConfig(mode: "Disabled")))
        #expect(!connection.sslEnabled)
        #expect(connection.sslConfiguration == nil)
    }

    // MARK: - Settings

    @Test(
        "A Mac confirmation level imports as Confirm Writes",
        arguments: ["alert", "alertFull", "safeMode", "safeModeFull"]
    )
    func macConfirmationLevelImportsAsConfirmWrites(_ wireValue: String) async throws {
        let connection = try await importedConnection(settings(safeModeLevel: wireValue))
        #expect(connection.safeModeLevel == .confirmWrites)
    }

    @Test("A Mac Silent connection imports as Off")
    func macSilentImportsAsOff() async throws {
        let connection = try await importedConnection(settings(safeModeLevel: "silent"))
        #expect(connection.safeModeLevel == .off)
    }

    @Test("A file with no level imports as Off")
    func missingLevelImportsAsOff() async throws {
        let connection = try await importedConnection(settings(safeModeLevel: nil))
        #expect(connection.safeModeLevel == .off)
    }

    @Test("An iOS level imports unchanged", arguments: SafeModeLevel.allCases)
    func iOSLevelImportsUnchanged(_ level: SafeModeLevel) async throws {
        let connection = try await importedConnection(settings(safeModeLevel: level.rawValue))
        #expect(connection.safeModeLevel == level)
    }

    @Test("A Read-Only level imports with the legacy read-only flag set")
    func readOnlyLevelSetsLegacyFlag() async throws {
        let connection = try await importedConnection(settings(safeModeLevel: "readOnly"))
        #expect(connection.isReadOnly)
    }

    @Test("An unrecognized level imports as Confirm Writes instead of Off")
    func unrecognizedLevelImportsAsConfirmWrites() async throws {
        let connection = try await importedConnection(settings(safeModeLevel: "someFutureLevel"))
        #expect(connection.safeModeLevel == .confirmWrites)
    }

    @Test("Explicit timeout overrides import with query zero intact")
    func explicitTimeoutOverridesImport() async throws {
        let connection = try await importedConnection(settings(
            connectTimeoutSeconds: 12,
            queryTimeoutSeconds: 0,
            additionalFields: [
                DatabaseConnection.connectTimeoutSecondsKey: "99",
                DatabaseConnection.queryTimeoutSecondsKey: "88",
                "schema": "public"
            ]
        ))

        #expect(connection.connectTimeoutSeconds == 12)
        #expect(connection.queryTimeoutSeconds == 0)
        #expect(connection.additionalFields["schema"] == "public")
    }

    @Test("Older additional fields migrate to timeout overrides")
    func legacyTimeoutAdditionalFieldsImport() async throws {
        let connection = try await importedConnection(settings(additionalFields: [
            DatabaseConnection.connectTimeoutSecondsKey: "15",
            DatabaseConnection.queryTimeoutSecondsKey: "0"
        ]))

        #expect(connection.connectTimeoutSeconds == 15)
        #expect(connection.queryTimeoutSeconds == 0)
    }

    @Test("Invalid explicit timeouts use defaults instead of legacy values")
    func invalidExplicitTimeoutsImportAsNil() async throws {
        let connection = try await importedConnection(settings(
            connectTimeoutSeconds: 601,
            queryTimeoutSeconds: -1,
            additionalFields: [
                DatabaseConnection.connectTimeoutSecondsKey: "15",
                DatabaseConnection.queryTimeoutSecondsKey: "30",
                "schema": "public"
            ]
        ))

        #expect(connection.connectTimeoutSeconds == nil)
        #expect(connection.queryTimeoutSeconds == nil)
        #expect(connection.additionalFields == ["schema": "public"])
    }

    @Test("Query timeout import accepts the maximum safe value")
    func queryTimeoutImportAcceptsMaximum() async throws {
        let maximum = DatabaseConnection.queryTimeoutSecondsRange.upperBound
        let connection = try await importedConnection(settings(queryTimeoutSeconds: maximum))
        #expect(connection.queryTimeoutSeconds == maximum)
    }

    @Test("Query timeout import rejects one second past the maximum")
    func queryTimeoutImportRejectsPastMaximum() async throws {
        let maximum = DatabaseConnection.queryTimeoutSecondsRange.upperBound
        let connection = try await importedConnection(settings(queryTimeoutSeconds: maximum + 1))
        #expect(connection.queryTimeoutSeconds == nil)
    }

    @Test("an imported jump host keeps its port, auth method and key path")
    func importKeepsJumpHostFields() async throws {
        let connection = try await importedConnection(settings(ssh: ExportableSSHConfig(
            enabled: true, host: "db-1", port: 22, username: "deploy",
            authMethod: "Password", privateKeyPath: "", agentSocketPath: "",
            jumpHosts: [
                ExportableJumpHost(
                    host: "bastion-1", port: nil, username: "ops",
                    authMethod: "Private Key", privateKeyPath: "~/.ssh/id_ed25519"
                )
            ],
            totpMode: nil, totpAlgorithm: nil, totpDigits: nil, totpPeriod: nil
        )))

        let hop = try #require(connection.sshConfiguration?.jumpHosts.first)
        #expect(hop.host == "bastion-1")
        #expect(hop.port == nil)
        #expect(hop.macAuthMethod == .privateKey)
        #expect(hop.macPrivateKeyPath == "~/.ssh/id_ed25519")
    }

    @Test("A file a shipped iOS build wrote imports with an unset port and a hop macOS can read")
    func importNormalizesLegacyIOSFile() async throws {
        let connection = try await importedConnection(settings(ssh: ExportableSSHConfig(
            enabled: true, host: "db-1", port: nil, username: "deploy",
            authMethod: "sshAgent", privateKeyPath: "", agentSocketPath: "",
            jumpHosts: [
                ExportableJumpHost(
                    host: "bastion-1", port: nil, username: "ops",
                    authMethod: "sshAgent", privateKeyPath: ""
                )
            ],
            totpMode: nil, totpAlgorithm: nil, totpDigits: nil, totpPeriod: nil
        )))

        let config = try #require(connection.sshConfiguration)
        #expect(config.port == nil)
        #expect(config.resolvedPort == 22)
        #expect(config.authMethod == .sshAgent)
        let hop = try #require(config.jumpHosts.first)
        #expect(hop.macAuthMethod == .sshAgent)
    }
}
