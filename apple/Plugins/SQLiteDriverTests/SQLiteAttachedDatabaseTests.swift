//
//  SQLiteAttachedDatabaseTests.swift
//  SQLiteDriverTests
//

import Foundation
import TableProPluginKit
import Testing

struct SQLiteAttachedDatabaseTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-attached-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func path(_ name: String) -> String {
        directory.appendingPathComponent(name).path
    }

    private func makeDatabase(_ name: String, _ statements: [String]) async throws {
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: path(name)
        ))
        try await driver.connect()
        for statement in statements {
            _ = try await driver.execute(query: statement)
        }
        driver.disconnect()
    }

    private func connect(attaching databases: [AttachedDatabase]) async throws -> SQLitePluginDriver {
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: path("app.db"),
            additionalFields: [AttachedDatabaseList.fieldId: AttachedDatabaseList.encode(databases)]
        ))
        try await driver.connect()
        return driver
    }

    private func prepareFiles() async throws {
        try await makeDatabase("app.db", [
            "CREATE TABLE users (id INTEGER PRIMARY KEY, label TEXT)",
            "INSERT INTO users VALUES (1, 'main user')"
        ])
        try await makeDatabase("auth.db", [
            "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL)",
            "CREATE INDEX users_email ON users (email)",
            "CREATE TABLE sessions (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users (id))",
            "CREATE TRIGGER sessions_audit AFTER INSERT ON sessions BEGIN SELECT 1; END",
            "INSERT INTO users VALUES (7, 'a@example.com')"
        ])
        try await makeDatabase("audit.db", [
            "CREATE TABLE events (user_id INTEGER, action TEXT)",
            "INSERT INTO events VALUES (7, 'login')"
        ])
    }

    @Test("Every listed file attaches on connect, so a cross-database join runs at once")
    func attachesOnConnect() async throws {
        try await prepareFiles()
        let driver = try await connect(attaching: [
            AttachedDatabase(name: "auth", path: path("auth.db")),
            AttachedDatabase(name: "audit", path: path("audit.db"))
        ])
        defer { driver.disconnect() }

        #expect(driver.connectionWarning == nil)
        #expect(try await driver.fetchSchemas() == ["auth", "audit"])
        let joined = try await driver.execute(query: """
            SELECT u.email, e.action FROM auth.users u JOIN audit.events e ON e.user_id = u.id
            """)
        #expect(joined.rows.first?.compactMap { $0.asText } == ["a@example.com", "login"])
    }

    @Test("A missing file is named in the warning and the others still attach")
    func missingFileIsNamed() async throws {
        try await prepareFiles()
        let missing = path("gone.db")
        let driver = try await connect(attaching: [
            AttachedDatabase(name: "gone", path: missing),
            AttachedDatabase(name: "auth", path: path("auth.db"))
        ])
        defer { driver.disconnect() }

        let warning = try #require(driver.connectionWarning)
        #expect(warning.contains(missing))
        #expect(try await driver.fetchSchemas() == ["auth"])
        #expect(!FileManager.default.fileExists(atPath: missing))
    }

    @Test("An attached database's catalog is read from that file, not from a same-named main table")
    func readsTheAttachedCatalog() async throws {
        try await prepareFiles()
        let driver = try await connect(attaching: [AttachedDatabase(name: "auth", path: path("auth.db"))])
        defer { driver.disconnect() }

        let tables = try await driver.fetchTables(schema: "auth")
        #expect(tables.map { $0.name } == ["sessions", "users"])
        #expect(tables.allSatisfy { $0.schema == "auth" })
        #expect(try await driver.fetchTables(schema: nil).map { $0.name } == ["users"])

        let columns = try await driver.fetchColumns(table: "users", schema: "auth")
        #expect(columns.map { $0.name } == ["id", "email"])
        #expect(columns.first { $0.name == "id" }?.isPrimaryKey == true)
        #expect(try await driver.fetchColumns(table: "users", schema: nil).map { $0.name } == ["id", "label"])

        let bulk = try await driver.fetchAllColumns(schema: "auth")
        #expect(bulk["users"]?.map { $0.name } == ["id", "email"])

        #expect(try await driver.fetchIndexes(table: "users", schema: "auth").contains { $0.name == "users_email" })
        #expect(try await driver.fetchIndexes(table: "users", schema: nil).allSatisfy { $0.name != "users_email" })

        let keys = try await driver.fetchForeignKeys(table: "sessions", schema: "auth")
        #expect(keys.first?.referencedTable == "users")
        #expect(keys.first?.referencedSchema == "auth")
        #expect(try await driver.fetchAllForeignKeys(schema: "auth")["sessions"]?.first?.referencedSchema == "auth")

        #expect(try await driver.fetchTableDDL(table: "users", schema: "auth").contains("email"))
        #expect(try await driver.fetchTriggers(table: "sessions", schema: "auth").map { $0.name } == ["sessions_audit"])
        #expect(try await driver.fetchAllTriggers(schema: nil).isEmpty)
        #expect(try await driver.fetchTableMetadata(table: "users", schema: "auth").rowCount == 1)
    }

    @Test("A temporary table lists apart from the attached databases, and each name reads its own catalog")
    func temporaryTableBesideAttachedDatabase() async throws {
        try await prepareFiles()
        let driver = try await connect(attaching: [AttachedDatabase(name: "auth", path: path("auth.db"))])
        defer { driver.disconnect() }
        _ = try await driver.execute(query: "CREATE TEMP TABLE users (id INTEGER, scratch TEXT, CONSTRAINT filled CHECK (scratch <> ''))")
        _ = try await driver.execute(query: "CREATE INDEX temp.users_scratch ON users (scratch)")
        _ = try await driver.execute(query: "CREATE TEMP TRIGGER users_note AFTER INSERT ON users BEGIN SELECT 1; END")

        #expect(try await driver.fetchTemporaryTables().map { $0.name } == ["users"])
        #expect(try await driver.fetchSchemas() == ["auth"])
        #expect(try await driver.fetchTables(schema: nil).map { $0.name } == ["users"])
        #expect(try await driver.fetchTables(schema: "auth").map { $0.name } == ["sessions", "users"])

        let temporaryDDL = try await driver.fetchTableDDL(table: "users", schema: nil)
        #expect(temporaryDDL.contains("scratch"))
        let attachedDDL = try await driver.fetchTableDDL(table: "users", schema: "auth")
        #expect(attachedDDL.contains("email"))
        #expect(!attachedDDL.contains("scratch"))

        #expect(try await driver.fetchCheckConstraints(table: "users", schema: nil).count == 1)
        #expect(try await driver.fetchCheckConstraints(table: "users", schema: "auth").isEmpty)
        #expect(try await driver.fetchIndexes(table: "users", schema: nil).map { $0.name } == ["users_scratch"])
        #expect(try await driver.fetchIndexes(table: "users", schema: "auth").map { $0.name } == ["users_email"])
        let attachedIndexDDL = try await driver.fetchIndexDDL(table: "users", schema: "auth")
        #expect(attachedIndexDDL.count == 1)
        #expect(attachedIndexDDL.first?.contains("users_email") == true)
        #expect(try await driver.fetchTriggers(table: "users", schema: nil).map { $0.name } == ["users_note"])
        #expect(try await driver.fetchTriggers(table: "sessions", schema: "auth").map { $0.name } == ["sessions_audit"])
        #expect(try await driver.fetchTriggers(table: "users", schema: "auth").isEmpty)
    }

    @Test("A schema name carrying a combining mark after a quote reads nothing it smuggled in")
    func schemaNameCannotInject() async throws {
        try await prepareFiles()
        let driver = try await connect(attaching: [AttachedDatabase(name: "auth", path: path("auth.db"))])
        defer { driver.disconnect() }

        let smuggled = "sqlite_master\"\u{301} WHERE 0 UNION ALL SELECT 'smuggled', 'table' /*"
        let tables = try? await driver.fetchTables(schema: smuggled)
        #expect(tables?.contains { $0.name == "smuggled" } != true)
        let columns = try? await driver.fetchColumns(table: "users", schema: "x'\u{301}) UNION SELECT 1,2,3,4,5,6,7 --")
        #expect(columns?.isEmpty ?? true)
    }

    @Test("Renaming a table in an attached database leaves the main table of that name alone")
    func renameStaysInTheAttachedDatabase() async throws {
        try await prepareFiles()
        let driver = try await connect(attaching: [AttachedDatabase(name: "auth", path: path("auth.db"))])
        defer { driver.disconnect() }

        try await driver.renameTable(name: "users", schema: "auth", to: "accounts", objectType: "TABLE")
        #expect(try await driver.fetchTables(schema: "auth").map { $0.name } == ["accounts", "sessions"])
        #expect(try await driver.fetchTables(schema: nil).map { $0.name } == ["users"])
    }

    @Test("A rebuild or reorder of a table in an attached database is refused, not run on the main file")
    func structureRebuildIsRefused() async throws {
        try await prepareFiles()
        let driver = try await connect(attaching: [AttachedDatabase(name: "auth", path: path("auth.db"))])
        defer { driver.disconnect() }

        await #expect(throws: SQLitePluginError.self) {
            _ = try await driver.columnReorderSchemaFingerprint(table: "users", schema: "auth")
        }
        await #expect(throws: SQLitePluginError.self) {
            _ = try await driver.generateColumnReorderPlan(
                table: "users", schema: "auth", columns: [], desiredOrder: ["email", "id"]
            )
        }
    }

    @Test("Maintenance on an attached table or database names that database")
    func maintenanceNamesTheDatabase() {
        #expect(SQLiteMaintenance.statements(operation: "ANALYZE", table: "users", schema: "auth")
            == ["ANALYZE `auth`.`users`"])
        #expect(SQLiteMaintenance.statements(operation: "REINDEX", table: "users", schema: "auth")
            == ["REINDEX `auth`.`users`"])
        #expect(SQLiteMaintenance.statements(operation: "VACUUM", table: nil, schema: "auth") == ["VACUUM `auth`"])
        #expect(SQLiteMaintenance.statements(operation: "Integrity Check", table: nil, schema: "auth")
            == ["PRAGMA `auth`.integrity_check"])
        #expect(SQLiteMaintenance.statements(operation: "REINDEX", table: nil, schema: "auth") == ["REINDEX"])
    }

    @Test("A trigger in an attached database is created and dropped by its qualified name")
    func triggerStatementsQualify() {
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: path("app.db")
        ))
        #expect(driver.generateDropTriggerSQL(name: "trg", table: "users", schema: "auth")
            == "DROP TRIGGER IF EXISTS `auth`.`trg`")
        #expect(driver.createTriggerTemplate(table: "users", schema: "auth")?.contains("`auth`.`trigger_name`") == true)
        #expect(driver.generateDropTriggerSQL(name: "trg", table: "users", schema: nil) == "DROP TRIGGER IF EXISTS `trg`")
    }
}
