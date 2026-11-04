//
//  BeekeeperStudioImporterTests.swift
//  TableProTests
//

import Foundation
import SQLite3
@testable import TablePro
import TableProImport
import Testing

struct BeekeeperStudioImporterTests {
    private let tempDir: URL
    private var importer: BeekeeperStudioImporter

    init() throws {
        tempDir = try ForeignFixture.makeTempDirectory("BeekeeperStudioImporterTests")
        var imp = BeekeeperStudioImporter()
        imp.dataDirectoryURL = tempDir
        importer = imp
    }

    // MARK: - Fixtures

    private static let connectionSchema = """
        CREATE TABLE saved_connection (
            id INTEGER PRIMARY KEY, name TEXT, connectionType TEXT, host TEXT, port INTEGER, username TEXT,
            defaultDatabase TEXT, password TEXT, ssl INTEGER DEFAULT 0, sslCaFile TEXT, sslCertFile TEXT,
            sslKeyFile TEXT, sslRejectUnauthorized INTEGER DEFAULT 0, trustServerCertificate INTEGER DEFAULT 0,
            sshEnabled INTEGER DEFAULT 0, sshHost TEXT, sshPort INTEGER, sshUsername TEXT, sshMode TEXT,
            sshKeyfile TEXT, sshKeyfilePassword TEXT, sshPassword TEXT, sshBastionHost TEXT,
            sshBastionHostPort INTEGER, sshBastionUsername TEXT, sshBastionMode TEXT, sshBastionKeyfile TEXT,
            labelColor TEXT, connectionFolderId INTEGER, workspaceId INTEGER DEFAULT -1
        );
        CREATE TABLE connection_folder (id INTEGER PRIMARY KEY, name TEXT);
        INSERT INTO connection_folder (id, name) VALUES (1, 'Production');
        INSERT INTO saved_connection (id, name, connectionType, host, port, username, defaultDatabase, connectionFolderId)
            VALUES (1, 'Shop', 'postgresql', 'db.example.com', 5432, 'app', 'shop', 1);
        INSERT INTO saved_connection (id, name, connectionType, host, port, workspaceId)
            VALUES (2, 'Cloud only', 'mysql', 'cloud.example.com', 3306, 7);
        """

    private func makeDatabase(_ sql: String) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(tempDir.appendingPathComponent("app.db").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func makeFoldersDatabase() throws {
        try makeDatabase(Self.connectionSchema + """
            CREATE TABLE query_folder (id INTEGER PRIMARY KEY, name TEXT, parentId INTEGER);
            CREATE TABLE favorite_query (
                id INTEGER PRIMARY KEY, title TEXT, text TEXT, database TEXT, connectionHash TEXT, queryFolderId INTEGER
            );
            INSERT INTO query_folder (id, name, parentId) VALUES (1, 'Reports', NULL), (2, 'Daily', 1);
            INSERT INTO favorite_query (id, title, text, queryFolderId) VALUES
                (1, 'Demo Query', 'select 1;', NULL),
                (2, 'Top customers', 'select * from customers where region = ${region};', NULL),
                (3, 'Daily active users', 'select count(*) from sessions;', 2),
                (4, 'Blank', '   ', NULL),
                (5, 'Huge', replace(hex(zeroblob(900001)), '00', 'x'), 1);
            """)
    }

    // MARK: - Connections

    @Test("collect imports local-workspace connections keyed by their Beekeeper id")
    func importsLocalConnections() throws {
        try makeFoldersDatabase()

        let result = try importer.collect(.connectionsOnly)

        #expect(result.connections.map { $0.name } == ["Shop"])
        #expect(result.bundle.connections.first?.ref == "1")
        #expect(result.groupPath(at: 0) == ["Production"])
        #expect(result.source == .foreignApp(name: "Beekeeper Studio"))
        #expect(result.bundle.savedQueries.isEmpty)
    }

    @Test("collect throws when app.db is missing")
    func missingDatabaseThrows() {
        #expect(throws: ForeignAppImportError.self) {
            try importer.collect(.withSavedQueries)
        }
    }

    // MARK: - Saved Queries

    @Test("collect reads saved queries with their folder tree under the Beekeeper Studio folder")
    func readsSavedQueriesWithFolders() throws {
        try makeFoldersDatabase()

        let result = try importer.collect(.withSavedQueries)

        #expect(result.savedQueryNames == ["Top customers", "Daily active users"])
        let daily = try #require(result.savedQuery(named: "Daily active users"))
        #expect(daily.sql == "select count(*) from sessions;")
        #expect(daily.connectionRef == nil)
        #expect(daily.keyword == nil)
        #expect(result.folderPath(of: daily) == ["Beekeeper Studio", "Reports", "Daily"])
        #expect(result.isSuggested(daily))

        let top = try #require(result.savedQuery(named: "Top customers"))
        #expect(top.sql == "select * from customers where region = ${region};")
        #expect(result.folderPath(of: top) == ["Beekeeper Studio"])
    }

    @Test("collect skips the seeded Demo Query and blank queries")
    func skipsDemoAndBlank() throws {
        try makeFoldersDatabase()

        let result = try importer.collect(.withSavedQueries)

        #expect(result.savedQuery(named: "Demo Query") == nil)
        #expect(result.savedQuery(named: "Blank") == nil)
    }

    @Test("A query over the sync limit is listed as oversized in its folder")
    func oversizedQuery() throws {
        try makeFoldersDatabase()

        let result = try importer.collect(.withSavedQueries)

        #expect(result.savedQuery(named: "Huge") == nil)
        let huge = try #require(result.oversizedQueries.first)
        #expect(huge.name == "Huge")
        #expect(huge.byteCount == 900_001)
        #expect(huge.folderPath == ["Beekeeper Studio", "Reports"])
        #expect(huge.connection == nil)
    }

    @Test("An older database without query folders imports its queries flat")
    func oldSchemaIsFlat() throws {
        try makeDatabase(Self.connectionSchema + """
            CREATE TABLE favorite_query (id INTEGER PRIMARY KEY, title TEXT, text TEXT, database TEXT, connectionHash TEXT);
            INSERT INTO favorite_query (id, title, text) VALUES (1, 'Orders', 'select * from orders;');
            """)

        let result = try importer.collect(.withSavedQueries)

        let orders = try #require(result.savedQuery(named: "Orders"))
        #expect(result.folderPath(of: orders) == ["Beekeeper Studio"])
    }

    @Test("A database without saved queries imports its connections")
    func noFavoriteTable() throws {
        try makeDatabase(Self.connectionSchema)

        let result = try importer.collect(.withSavedQueries)

        #expect(result.connections.count == 1)
        #expect(result.bundle.savedQueries.isEmpty)
    }

    @Test("inventory counts connections and saved queries without the demo or blank rows")
    func inventoryCounts() throws {
        try makeFoldersDatabase()

        #expect(importer.inventory() == ForeignAppInventory(connections: 1, savedQueries: 3))
    }

    @Test("inventory counts only the connections collect imports")
    func inventorySkipsUntypedConnections() throws {
        try makeDatabase(Self.connectionSchema + """
            INSERT INTO saved_connection (id, name, connectionType, host) VALUES (3, 'No type', NULL, 'h');
            """)

        let result = try importer.collect(.connectionsOnly)

        #expect(result.connections.map { $0.name } == ["Shop"])
        #expect(importer.inventory().connections == result.connections.count)
    }

    @Test("inventory and collect agree on which saved queries are blank")
    func blankQueriesAgree() throws {
        try makeDatabase(Self.connectionSchema + """
            CREATE TABLE favorite_query (id INTEGER PRIMARY KEY, title TEXT, text TEXT);
            INSERT INTO favorite_query (id, title, text) VALUES
                (1, 'Orders', 'select * from orders;'),
                (2, 'Form feed', char(12)),
                (3, 'Blank', ' ' || char(9) || char(10) || char(13));
            """)

        let result = try importer.collect(.withSavedQueries)

        #expect(result.savedQueryNames == ["Orders", "Form feed"])
        #expect(importer.inventory().savedQueries == result.bundle.savedQueries.count)
    }

    @Test("TLS verification follows what each engine's Beekeeper connector does")
    func tlsVerificationPerEngine() throws {
        // Beekeeper saves sslRejectUnauthorized and trustServerCertificate as 1 unless the user turns them off.
        try makeDatabase(Self.connectionSchema + """
            INSERT INTO saved_connection (id, name, connectionType, host, ssl, sslCaFile, sslCertFile, sslKeyFile,
                sslRejectUnauthorized, trustServerCertificate) VALUES
                (11, 'PG no files', 'postgresql', 'pg', 1, NULL, NULL, NULL, 1, 1),
                (12, 'PG with CA', 'postgresql', 'pg', 1, '/certs/ca.pem', NULL, NULL, 1, 1),
                (13, 'PG unverified', 'postgresql', 'pg', 1, '/certs/ca.pem', NULL, NULL, 0, 1),
                (14, 'MySQL no files', 'mysql', 'my', 1, NULL, NULL, NULL, 1, 1),
                (15, 'SQL Server', 'sqlserver', 'ms', 1, NULL, NULL, NULL, 0, 1),
                (16, 'SQL Server trusted', 'sqlserver', 'ms', 1, '/certs/ca.pem', '/certs/c.pem', '/certs/c.key', 0, 0),
                (17, 'Redis', 'redis', 'cache', 1, NULL, NULL, NULL, 1, 1);
            """)

        var modes: [String: PortableSSLMode] = [:]
        for connection in try importer.collect(.connectionsOnly).connections {
            modes[connection.name] = connection.sslConfig?.portableMode
        }

        #expect(modes["PG no files"] == .required)
        #expect(modes["PG with CA"] == .verifyIdentity)
        #expect(modes["PG unverified"] == .required)
        #expect(modes["MySQL no files"] == .required)
        #expect(modes["SQL Server"] == .verifyIdentity)
        #expect(modes["SQL Server trusted"] == .required)
        #expect(modes["Redis"] == .verifyIdentity)
    }

    @Test("With SSL off only SQL Server encrypts, as mssql does by default")
    func tlsWithSSLOff() throws {
        try makeDatabase(Self.connectionSchema + """
            INSERT INTO saved_connection (id, name, connectionType, host, ssl, sslRejectUnauthorized, trustServerCertificate)
                VALUES
                (21, 'SQL Server trusting', 'sqlserver', 'ms', 0, 1, 1),
                (22, 'SQL Server checking', 'sqlserver', 'ms', 0, 1, 0),
                (23, 'PG plain', 'postgresql', 'pg', 0, 1, 1),
                (24, 'MySQL plain', 'mysql', 'my', 0, 1, 1);
            """)

        let collected = try importer.collect(.connectionsOnly)
        let connections = Dictionary(uniqueKeysWithValues: collected.connections.map { ($0.name, $0) })

        let trusting = try #require(connections["SQL Server trusting"]?.sslConfig)
        #expect(trusting.portableMode == .required)
        #expect(trusting.caCertificatePath == nil)
        #expect(connections["SQL Server checking"]?.sslConfig?.portableMode == .verifyIdentity)
        #expect(connections["PG plain"]?.sslConfig == nil)
        #expect(connections["MySQL plain"]?.sslConfig == nil)

        #expect(collected.notes(named: "SQL Server trusting") == [
            "SSL Required (skip verify) is on because Beekeeper Studio encrypts this connection by default"
        ])
        #expect(collected.notes(named: "SQL Server checking") == [
            "SSL Verify Identity is on because Beekeeper Studio encrypts this connection by default"
        ])
        #expect(collected.notes(named: "PG plain").isEmpty)
        #expect(collected.notes(named: "MySQL plain").isEmpty)
    }

    @Test("Saved queries import as global queries in a folder named after the app")
    func savedQuerySupport() {
        guard case .reads(let caption) = importer.savedQuerySupport else {
            Issue.record("Beekeeper Studio should read saved queries")
            return
        }
        #expect(caption.contains("Beekeeper Studio"))
    }
}
