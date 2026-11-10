import Foundation
import TableProPluginKit
import Testing

struct SQLiteColumnOriginsTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-column-origins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static var external: PluginStatementContext {
        var context = PluginStatementContext()
        context.origin = .external
        context.hostSplit = true
        context.allowsServerCode = false
        return context
    }

    private static var externalRead: PluginStatementContext {
        var context = external
        context.readOnly = true
        return context
    }

    private static let email = PluginColumnOrigin(schema: "main", table: "users", column: "email")

    private func connect() async throws -> SQLitePluginDriver {
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: directory.appendingPathComponent("app.db").path
        ))
        try await driver.connect()
        _ = try await driver.execute(query: "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)")
        _ = try await driver.execute(query: "CREATE TABLE t (id INTEGER)")
        _ = try await driver.execute(query: "INSERT INTO users VALUES (1, 'jane@example.com')")
        _ = try await driver.execute(query: "INSERT INTO t VALUES (7)")
        return driver
    }

    // The streamed read is the one MCP takes, with a row cap; the whole read is the one without.
    private func origins(of sql: String, on driver: SQLitePluginDriver) async throws -> [[PluginColumnOrigin?]?] {
        let streamed = try await driver.executeUserQuery(query: sql, rowCap: 10, parameters: nil, context: Self.externalRead)
        let whole = try await driver.executeUserQuery(query: sql, rowCap: nil, parameters: nil, context: Self.externalRead)
        return [streamed.columnOrigins, whole.columnOrigins]
    }

    @Test("A column renamed by an alias, a subquery or a CTE still names the column it reads")
    func renamedColumnsKeepTheirOrigin() async throws {
        let driver = try await connect()
        defer { driver.disconnect() }

        for sql in [
            "SELECT email AS e FROM users",
            "SELECT e FROM (SELECT email AS e FROM users) s",
            "WITH c AS (SELECT email AS e FROM users) SELECT e FROM c",
        ] {
            #expect(try await origins(of: sql, on: driver) == [[Self.email], [Self.email]], "\(sql)")
        }
    }

    @Test("An expression reports no origin")
    func expressionHasNoOrigin() async throws {
        let driver = try await connect()
        defer { driver.disconnect() }

        #expect(try await origins(of: "SELECT lower(email), id FROM users", on: driver) == [
            [nil, PluginColumnOrigin(schema: "main", table: "users", column: "id")],
            [nil, PluginColumnOrigin(schema: "main", table: "users", column: "id")],
        ])
    }

    // Measured: SQLite reports `t.id` for this column, which holds the e-mail addresses too.
    @Test("A compound SELECT reports no origins at all")
    func compoundSelectHasNoOrigins() async throws {
        let driver = try await connect()
        defer { driver.disconnect() }

        #expect(try await origins(of: "SELECT id FROM t UNION SELECT email FROM users", on: driver) == [[nil], [nil]])
        #expect(try await origins(of: "SELECT e FROM (SELECT id AS e FROM t EXCEPT SELECT 1)", on: driver) == [[nil], [nil]])
    }

    // A browse writes filter values as literals, so `'union'` in one used to read as "no origins", which a browse
    // takes as proof by name.
    @Test("A word in a filter value leaves every column untrusted, never without origins")
    func filterValueWordKeepsColumnsUntrusted() async throws {
        let driver = try await connect()
        defer { driver.disconnect() }
        _ = try await driver.execute(query: "CREATE VIRTUAL TABLE contacts USING fts5(email, note)")
        _ = try await driver.execute(query: "INSERT INTO contacts VALUES ('jane@example.com', 'n')")

        #expect(try await origins(
            of: "SELECT c0, c1 FROM contacts_content WHERE c0 != 'union'", on: driver
        ) == [[nil, nil], [nil, nil]])
    }

    // Measured: both report `main.t.id` for a column holding the e-mail address too.
    @Test("A multi-row VALUES reports no origins at all")
    func valuesRowsHaveNoOrigins() async throws {
        let driver = try await connect()
        defer { driver.disconnect() }

        #expect(try await origins(of: "VALUES ((SELECT id FROM t)), ((SELECT email FROM users))", on: driver) == [[nil], [nil]])
        #expect(try await origins(
            of: "SELECT column1 FROM (VALUES ((SELECT email FROM users)), ((SELECT id FROM t)))", on: driver
        ) == [[nil], [nil]])
    }

    @Test("A statement with no result columns is not scanned")
    func noColumnsNoOrigins() async throws {
        let driver = try await connect()
        defer { driver.disconnect() }

        let insert = try await driver.executeUserQuery(
            query: "INSERT INTO t VALUES (8)", rowCap: nil, parameters: nil, context: Self.external
        )
        #expect(insert.columnOrigins == [])
    }

    @Test("A table-valued function's column is no table column")
    func tableValuedFunctionHasNoOrigin() async throws {
        let driver = try await connect()
        defer { driver.disconnect() }

        let sql = "SELECT j.value AS id FROM users, json_each(json_array(users.email)) j"
        #expect(try await origins(of: sql, on: driver) == [[nil], [nil]])
    }

    @Test("SQLite's own tables report no origin")
    func systemTablesHaveNoOrigin() async throws {
        let driver = try await connect()
        defer { driver.disconnect() }

        #expect(try await origins(of: "SELECT name, sql FROM sqlite_schema", on: driver) == [[nil, nil], [nil, nil]])
    }

    // Measured: `contacts_content.c0` passed the metadata lookup and held the indexed address.
    @Test("An FTS table's shadow copy reports no origin, while the FTS table's own columns do")
    func shadowTablesHaveNoOrigin() async throws {
        let driver = try await connect()
        defer { driver.disconnect() }
        _ = try await driver.execute(query: "CREATE VIRTUAL TABLE contacts USING fts5(email, note)")
        _ = try await driver.execute(query: "INSERT INTO contacts VALUES ('jane@example.com', 'n')")

        #expect(try await origins(of: "SELECT c0, c1 FROM contacts_content", on: driver) == [[nil, nil], [nil, nil]])
        let email = PluginColumnOrigin(schema: "main", table: "contacts", column: "email")
        #expect(try await origins(of: "SELECT email AS e FROM contacts", on: driver) == [[email], [email]])
    }

    @Test("A compound operator is found as a word, not inside an identifier")
    func compoundWords() {
        #expect(SQLiteColumnOrigins.hasCompoundSelect("select 1 union select 2"))
        #expect(SQLiteColumnOrigins.hasCompoundSelect("SELECT 1 INTERSECT SELECT 1"))
        #expect(SQLiteColumnOrigins.hasCompoundSelect("SELECT 1 /* x */EXCEPT SELECT 2"))
        #expect(SQLiteColumnOrigins.hasCompoundSelect("VALUES (1), (2)"))
        #expect(!SQLiteColumnOrigins.hasCompoundSelect("SELECT reunion, exceptions, value_count FROM union_members"))
    }
}
