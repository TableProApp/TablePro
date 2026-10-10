import Foundation
import Testing

@testable import TableProImport

@Suite("Connection import analyzer")
struct ConnectionImportAnalyzerTests {
    private typealias Fixtures = ImportFixtures

    @Test("A connection matching host, port, database and username ignoring case and spaces is a duplicate")
    func duplicateMatchingUsesConnectionDetails() throws {
        let existingId = UUID()
        let local = Fixtures.settings(name: "Local Postgres", host: "db.example.com", database: "app", username: "admin")
        let imported = Fixtures.settings(
            name: "Different Name", host: " db.example.com ", database: " app ", username: " ADMIN ", type: "MySQL"
        )
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [BundleConnection(ref: "c1", settings: imported)]),
            library: ImportLibrarySnapshot(connections: [Fixtures.existing(local, id: existingId)])
        )

        let row = try #require(preview.connections.first)
        #expect(row.duplicate == ExistingConnection(id: existingId, name: "Local Postgres"))
        #expect(row.resolutions == [.addCopy, .replace(existingId)])
        #expect(!row.isSelectedByDefault)
    }

    @Test("The first library connection with a matching key is the duplicate")
    func firstExistingMatchWins() throws {
        let first = UUID()
        let library = ImportLibrarySnapshot(connections: [
            Fixtures.existing(Fixtures.settings(), id: first, name: "First"),
            Fixtures.existing(Fixtures.settings(), id: UUID(), name: "Second")
        ])
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [BundleConnection(ref: "c1", settings: Fixtures.settings())]),
            library: library
        )

        #expect(try #require(preview.connections.first).duplicate?.id == first)
    }

    @Test("A different username on the same host is not a duplicate")
    func differentUsernameIsNotADuplicate() throws {
        let library = ImportLibrarySnapshot(connections: [Fixtures.existing(Fixtures.settings(username: "admin"))])
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings(username: "readonly"))
            ]),
            library: library
        )

        let row = try #require(preview.connections.first)
        #expect(row.duplicate == nil)
        #expect(row.resolutions == [.add])
        #expect(row.isSelectedByDefault)
    }

    @Test("Redis connections differ by database index and match on the same one")
    func redisDatabaseIndexDistinguishesDuplicates() throws {
        var local = Fixtures.settings(name: "Redis 0", port: 6_379, database: "", username: "cache", type: "Redis")
        local.redisDatabase = 0
        var other = local
        other.redisDatabase = 1
        let library = ImportLibrarySnapshot(connections: [Fixtures.existing(local)])
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [
                BundleConnection(ref: "c1", settings: other),
                BundleConnection(ref: "c2", settings: local)
            ]),
            library: library
        )

        #expect(preview.connections[0].duplicate == nil)
        #expect(preview.connections[1].duplicate != nil)
    }

    @Test("An unknown type is unsupported, kept as written and not selected")
    func unknownTypeIsUnsupported() throws {
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [BundleConnection(ref: "c1", settings: Fixtures.settings(type: "Vertica"))])
        )

        let row = try #require(preview.connections.first)
        #expect(row.unsupportedTypeId == "Vertica")
        #expect(row.settings.type == "Vertica")
        #expect(!row.isSelectedByDefault)
    }

    @Test("A type differing only in case is canonicalized")
    func typeIsCanonicalized() throws {
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings(type: "postgresql"))
            ])
        )

        let row = try #require(preview.connections.first)
        #expect(row.settings.type == "PostgreSQL")
        #expect(row.unsupportedTypeId == nil)
        #expect(row.isSelectedByDefault)
    }

    @Test("A duplicate of an unsupported type stays a duplicate")
    func duplicateOfUnsupportedTypeStaysDuplicate() throws {
        let library = ImportLibrarySnapshot(connections: [Fixtures.existing(Fixtures.settings())])
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [BundleConnection(ref: "c1", settings: Fixtures.settings(type: "Vertica"))]),
            library: library
        )

        let row = try #require(preview.connections.first)
        #expect(row.duplicate != nil)
        #expect(row.unsupportedTypeId == "Vertica")
    }

    @Test("The resolver prefers an exact match")
    func resolverPrefersExactMatch() {
        #expect(ConnectionTypeResolver.canonicalTypeId("LIBSQL", registeredTypeIds: ["libSQL", "LIBSQL"]) == "LIBSQL")
    }

    @Test("The resolver refuses an ambiguous case-insensitive match")
    func resolverRefusesAmbiguousMatch() {
        #expect(ConnectionTypeResolver.canonicalTypeId("libsql", registeredTypeIds: ["libSQL", "LIBSQL"]) == nil)
    }

    @Test("The resolver returns nil for empty and unknown types")
    func resolverReturnsNilForUnknownTypes() {
        #expect(ConnectionTypeResolver.canonicalTypeId("", registeredTypeIds: Fixtures.registeredTypeIds) == nil)
        #expect(ConnectionTypeResolver.canonicalTypeId("Greenplum", registeredTypeIds: Fixtures.registeredTypeIds) == nil)
    }

    @Test("Missing SSH and jump host keys and certificate paths each warn")
    func missingFilesWarn() throws {
        var settings = Fixtures.settings()
        settings.sshConfig = ExportableSSHConfig(
            enabled: true,
            host: "bastion",
            port: nil,
            username: "u",
            authMethod: "privateKey",
            privateKeyPath: "~/.ssh/missing_key",
            agentSocketPath: "",
            jumpHosts: [
                ExportableJumpHost(host: "jump", port: nil, username: "u", authMethod: "privateKey", privateKeyPath: "~/.ssh/jump")
            ],
            totpMode: nil,
            totpAlgorithm: nil,
            totpDigits: nil,
            totpPeriod: nil
        )
        settings.sslConfig = ExportableSSLConfig(
            mode: "Required",
            caCertificatePath: "~/ca.pem",
            clientCertificatePath: "~/client.pem",
            clientKeyPath: "~/client.key"
        )
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [BundleConnection(ref: "c1", settings: settings)]),
            environment: Fixtures.makeEnvironment(fileExists: { _ in false })
        )

        let warnings = try #require(preview.connections.first).warnings
        #expect(warnings.count == 5)
        #expect(warnings.contains { $0.contains("SSH private key") && $0.contains("~/.ssh/missing_key") })
        #expect(warnings.contains { $0.contains("Jump host key") })
        #expect(warnings.contains { $0.contains("CA certificate") })
        #expect(warnings.contains { $0.contains("Client certificate") })
        #expect(warnings.contains { $0.contains("Client key") })
    }

    @Test("An unrecognized SSL mode warns that the connection imports with SSL required")
    func unrecognizedSSLModeWarns() throws {
        var settings = Fixtures.settings()
        settings.sslConfig = ExportableSSLConfig(mode: "sometimes")
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [BundleConnection(ref: "c1", settings: settings)])
        )

        let row = try #require(preview.connections.first)
        #expect(row.warnings.count == 1)
        #expect(row.warnings.first?.contains("“sometimes”") == true)
        #expect(row.warnings.first?.contains("SSL required") == true)
        #expect(row.isSelectedByDefault)
    }

    @Test("An iOS SSL spelling is recognized and does not warn")
    func iOSSpellingDoesNotWarn() throws {
        var settings = Fixtures.settings()
        settings.sslConfig = ExportableSSLConfig(mode: "verifyFull")
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [BundleConnection(ref: "c1", settings: settings)])
        )

        #expect(try #require(preview.connections.first).warnings.isEmpty)
    }

    @Test("A registered type whose plugin is not installed warns, duplicates included")
    func missingDriverWarns() throws {
        let library = ImportLibrarySnapshot(connections: [Fixtures.existing(Fixtures.settings(name: "Cache", type: "Redis"))])
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings(type: "redis")),
                BundleConnection(ref: "c2", settings: Fixtures.settings(host: "other", type: "MySQL"))
            ]),
            library: library,
            environment: Fixtures.makeEnvironment(missingDriverNames: ["Redis": "Redis Driver"])
        )

        #expect(preview.connections[0].duplicate != nil)
        #expect(preview.connections[0].warnings == [
            "The Redis Driver plugin is not installed. TablePro offers to install it on connect."
        ])
        #expect(preview.connections[1].warnings.isEmpty)
    }

    @Test("A duplicate carrying saved queries defaults to Keep Existing, Add Queries")
    func keepExistingOnlyWithQueries() throws {
        let existingId = UUID()
        let library = ImportLibrarySnapshot(connections: [Fixtures.existing(Fixtures.settings(), id: existingId)])
        let bundle = try Fixtures.makeBundle(
            connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings()),
                BundleConnection(ref: "c2", settings: Fixtures.settings(name: "Twin"))
            ],
            savedQueries: [BundleSavedQuery(ref: "q1", name: "Locks", sql: "select 1", connectionRef: "c1")]
        )
        let preview = Fixtures.makePreview(bundle, library: library)

        #expect(preview.connections[0].savedQueryCount == 1)
        #expect(preview.connections[0].resolutions == [.keepExisting(existingId), .addCopy, .replace(existingId)])
        #expect(preview.connections[1].savedQueryCount == 0)
        #expect(preview.connections[1].resolutions == [.addCopy, .replace(existingId)])
    }

    @Test("Cloud discovery never offers Replace")
    func cloudDiscoveryOffersNoReplace() throws {
        let existingId = UUID()
        let library = ImportLibrarySnapshot(connections: [Fixtures.existing(Fixtures.settings(), id: existingId)])
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [BundleConnection(ref: "c1", settings: Fixtures.settings())]),
            source: .cloudDiscovery(name: "AWS"),
            library: library
        )

        #expect(try #require(preview.connections.first).resolutions == [.addCopy])
    }

    @Test("Rules without saved queries list no query rows and offer no Keep Existing")
    func rulesWithoutSavedQueries() throws {
        let existingId = UUID()
        let library = ImportLibrarySnapshot(connections: [Fixtures.existing(Fixtures.settings(), id: existingId)])
        let bundle = try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: Fixtures.settings())],
            savedQueries: [
                BundleSavedQuery(ref: "q1", name: "Locks", sql: "select 1", connectionRef: "c1"),
                BundleSavedQuery(ref: "q2", name: "Global", sql: "select 2")
            ]
        )
        let preview = Fixtures.makePreview(
            bundle,
            library: library,
            environment: Fixtures.makeEnvironment(rules: Fixtures.makeRules(supportsSavedQueries: false))
        )

        let row = try #require(preview.connections.first)
        #expect(preview.queries.isEmpty)
        #expect(row.savedQueryCount == 0)
        #expect(row.resolutions == [.addCopy, .replace(existingId)])
    }

    @Test("Exact duplicate queries in one file collapse to the first")
    func inFileDuplicateQueriesCollapse() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: Fixtures.settings())],
            savedQueries: [
                BundleSavedQuery(ref: "q1", name: "Locks", sql: "select 1", connectionRef: "c1"),
                BundleSavedQuery(ref: "q2", name: " locks ", sql: "select 1\n", connectionRef: "c1"),
                BundleSavedQuery(ref: "q3", name: "Locks", sql: "select 1"),
                BundleSavedQuery(ref: "q4", name: "Locks", sql: "select 2", connectionRef: "c1")
            ]
        )
        let preview = Fixtures.makePreview(bundle)

        #expect(preview.queries.map(\.ref) == ["q1", "q3", "q4"])
        #expect(preview.connections.first?.savedQueryCount == 2)
    }

    @Test("Query rows carry their connection, folder path, keyword and a derived name when blank")
    func queryRowsDescribeTheFile() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: Fixtures.settings(name: "Orders"))],
            queryFolders: [
                BundleQueryFolder(ref: "f1", name: "Reports", connectionRef: "c1"),
                BundleQueryFolder(ref: "f2", name: "Daily", parentRef: "f1", connectionRef: "c1")
            ],
            savedQueries: [
                BundleSavedQuery(ref: "q1", name: "  ", sql: "-- Active users\nselect 1", keyword: " dau ", folderRef: "f2", connectionRef: "c1"),
                BundleSavedQuery(ref: "q2", name: "Locks", sql: "select 2")
            ]
        )
        let preview = Fixtures.makePreview(bundle, unsuggestedQueries: ["q2"])

        let scoped = try #require(preview.queryRow("q1"))
        #expect(scoped.name == "Active users")
        #expect(scoped.keyword == "dau")
        #expect(scoped.connection == "c1")
        #expect(scoped.connectionName == "Orders")
        #expect(scoped.folderPath == ["Reports", "Daily"])
        #expect(scoped.isSuggested)
        #expect(!scoped.isTooLarge)

        let global = try #require(preview.queryRow("q2"))
        #expect(global.connection == nil)
        #expect(global.connectionName == nil)
        #expect(global.folderPath.isEmpty)
        #expect(!global.isSuggested)
    }

    @Test("A query over the sync limit is too large, and oversized foreign files follow the bundle rows")
    func oversizedQueriesAreListed() throws {
        let large = String(repeating: "x", count: SavedQuerySize.maximumSyncableByteCount)
        let bundle = try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: Fixtures.settings())],
            savedQueries: [
                BundleSavedQuery(ref: "q1", name: "Huge", sql: large),
                BundleSavedQuery(ref: "q2", name: "Small", sql: "select 1")
            ]
        )
        let oversized = OversizedSavedQuery(
            ref: "q3", name: "Dump", folderPath: ["DBeaver"], connection: "c1", byteCount: 2_000_000
        )
        let preview = Fixtures.makePreview(bundle, oversizedQueries: [oversized])

        #expect(preview.queries.map(\.ref) == ["q1", "q2", "q3"])
        #expect(preview.queries.map(\.isTooLarge) == [true, false, true])
        #expect(preview.queries[0].byteCount == SavedQuerySize.maximumSyncableByteCount + 4)
        #expect(preview.queries[2].byteCount == 2_000_000)
        #expect(preview.queries[2].connectionName == "Orders")
        #expect(preview.connections.first?.savedQueryCount == 1)
    }

    @Test("An unsuggested connection is not selected by default")
    func unsuggestedConnectionIsNotSelected() throws {
        let preview = Fixtures.makePreview(
            try Fixtures.makeBundle(connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings()),
                BundleConnection(ref: "c2", settings: Fixtures.settings(host: "reader"))
            ]),
            unsuggestedConnections: ["c2"]
        )

        #expect(preview.connections.map(\.isSelectedByDefault) == [true, false])
    }

    @Test("The group path follows the chain, root first, clamped to the depth limit")
    func groupPathIsClamped() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: Fixtures.settings(), groupRef: "g4")],
            groups: [
                BundleGroup(ref: "g1", name: "Client A"),
                BundleGroup(ref: "g2", name: " Production ", parentRef: "g1"),
                BundleGroup(ref: "g3", name: "EU", parentRef: "g2"),
                BundleGroup(ref: "g4", name: "Primary", parentRef: "g3")
            ]
        )
        let preview = Fixtures.makePreview(bundle)

        #expect(preview.connections.first?.groupPath == ["Client A", "Production", "EU"])
    }
}
