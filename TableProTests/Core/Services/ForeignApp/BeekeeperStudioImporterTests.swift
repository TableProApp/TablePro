//
//  BeekeeperStudioImporterTests.swift
//  TableProTests
//

import Foundation
import SQLite3
@testable import TablePro
import TableProImport
import Testing

@Suite("BeekeeperStudioImporter", .serialized)
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

    @Test("Saved queries import as global queries in a folder named after the app")
    func savedQuerySupport() {
        guard case .reads(let caption) = importer.savedQuerySupport else {
            Issue.record("Beekeeper Studio should read saved queries")
            return
        }
        #expect(caption.contains("Beekeeper Studio"))
    }
}
