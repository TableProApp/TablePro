//
//  SQLiteForeignKeyReadTests.swift
//  SQLiteDriverTests
//

import Foundation
import TableProPluginKit
import Testing

struct SQLiteForeignKeyReadTests {
    private func withDriver(
        _ statements: [String],
        _ body: (SQLitePluginDriver) async throws -> Void
    ) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-fk-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: url.path
        ))
        try await driver.connect()
        defer { driver.disconnect() }
        for statement in statements {
            _ = try await driver.execute(query: statement)
        }
        try await body(driver)
    }

    // Per-table and bulk reads feed different surfaces (Structure tab, ER diagram, Compare) and must agree.
    private func bothReads(_ driver: SQLitePluginDriver, table: String) async throws -> [[PluginForeignKeyInfo]] {
        let single = try await driver.fetchForeignKeys(table: table, schema: nil)
        let bulk = try await driver.fetchAllForeignKeys(schema: nil)[table] ?? []
        return [single, bulk]
    }

    @Test("A declared name equal to another key's positional name keeps the two keys apart")
    func declaredNameSpellingAPositionalName() async throws {
        try await withDriver([
            "CREATE TABLE p (id INTEGER PRIMARY KEY)",
            """
            CREATE TABLE orders (
                id INTEGER PRIMARY KEY, a INTEGER, b INTEGER,
                CONSTRAINT fk_orders_0 FOREIGN KEY (a) REFERENCES p (id),
                FOREIGN KEY (b) REFERENCES p (id)
            )
            """
        ]) { driver in
            for keys in try await bothReads(driver, table: "orders") {
                #expect(keys.first { $0.column == "a" }?.name == "fk_orders_0")
                #expect(keys.first { $0.column == "b" }?.name == "fk_orders_0_2")
            }
        }
    }

    @Test("Two keys on one relationship with different actions keep their own names")
    func sameRelationshipDifferentActions() async throws {
        try await withDriver([
            "CREATE TABLE p (id INTEGER PRIMARY KEY)",
            """
            CREATE TABLE t (
                x INTEGER,
                CONSTRAINT restrict_key FOREIGN KEY (x) REFERENCES p (id) ON DELETE RESTRICT,
                CONSTRAINT cascade_key FOREIGN KEY (x) REFERENCES p (id) ON DELETE CASCADE
            )
            """
        ]) { driver in
            for keys in try await bothReads(driver, table: "t") {
                #expect(keys.first { $0.onDelete == "RESTRICT" }?.name == "restrict_key")
                #expect(keys.first { $0.onDelete == "CASCADE" }?.name == "cascade_key")
            }
        }
    }

    @Test("A shorthand key to a parent with a non-ASCII name reads the parent's primary key")
    func shorthandKeyToNonASCIIParent() async throws {
        try await withDriver([
            "CREATE TABLE \"Équipe\" (id INTEGER PRIMARY KEY, name TEXT)",
            "CREATE TABLE members (id INTEGER PRIMARY KEY, team_id INTEGER REFERENCES \"Équipe\")"
        ]) { driver in
            for keys in try await bothReads(driver, table: "members") {
                #expect(keys.map(\.referencedTable) == ["Équipe"])
                #expect(keys.map(\.referencedColumn) == ["id"])
            }
        }
    }

    // SQLite folds ASCII case only, so these are two tables, each with its own key.
    @Test("Parents whose names differ only in non-ASCII case resolve to their own keys")
    func parentsDifferingInNonASCIICase() async throws {
        try await withDriver([
            "CREATE TABLE \"Équipe\" (id INTEGER PRIMARY KEY)",
            "CREATE TABLE \"équipe\" (code TEXT PRIMARY KEY)",
            "CREATE TABLE child (a INTEGER REFERENCES \"Équipe\", b TEXT REFERENCES \"équipe\")"
        ]) { driver in
            for keys in try await bothReads(driver, table: "child") {
                #expect(keys.first { $0.column == "a" }?.referencedColumn == "id")
                #expect(keys.first { $0.column == "b" }?.referencedColumn == "code")
            }
        }
    }

    @Test("A composite shorthand key reads the parent's primary key in key order")
    func compositeShorthandKey() async throws {
        try await withDriver([
            "CREATE TABLE users (tenant_id INTEGER, id INTEGER, PRIMARY KEY (tenant_id, id))",
            "CREATE TABLE orders (tid INTEGER, uid INTEGER, FOREIGN KEY (tid, uid) REFERENCES USERS)"
        ]) { driver in
            for keys in try await bothReads(driver, table: "orders") {
                #expect(keys.map(\.column) == ["tid", "uid"])
                #expect(keys.map(\.referencedColumn) == ["tenant_id", "id"])
                #expect(Set(keys.map(\.name)).count == 1)
            }
        }
    }

    @Test("A table name spelled in another case still reads its keys")
    func tableNameCaseInsensitive() async throws {
        try await withDriver([
            "CREATE TABLE p (id INTEGER PRIMARY KEY)",
            "CREATE TABLE orders (pid INTEGER REFERENCES p (id))"
        ]) { driver in
            let keys = try await driver.fetchForeignKeys(table: "ORDERS", schema: nil)
            #expect(keys.map(\.column) == ["pid"])
        }
    }

    @Test("A temporary table reads its keys")
    func temporaryTable() async throws {
        try await withDriver([
            "CREATE TEMP TABLE parent (k INTEGER PRIMARY KEY)",
            "CREATE TEMP TABLE child (x INTEGER REFERENCES parent)"
        ]) { driver in
            let keys = try await driver.fetchForeignKeys(table: "child", schema: nil)
            #expect(keys.map(\.referencedColumn) == ["k"])
        }
    }

    // `_` is a LIKE wildcard, so `NOT LIKE 'sqlite_%'` hid any user table whose name starts with "sqlite".
    @Test("A user table whose name starts with sqlite is listed with its keys")
    func tableNamedLikeAnInternalOne() async throws {
        try await withDriver([
            "CREATE TABLE p (id INTEGER PRIMARY KEY)",
            "CREATE TABLE sqlitebrowser_backup (pid INTEGER REFERENCES p (id))"
        ]) { driver in
            let tables = try await driver.fetchTables(schema: nil).map(\.name)
            #expect(tables.contains("sqlitebrowser_backup"))
            let columns = try await driver.fetchAllColumns(schema: nil)
            #expect(columns["sqlitebrowser_backup"]?.map(\.name) == ["pid"])
            let keys = try await driver.fetchAllForeignKeys(schema: nil)
            #expect(keys["sqlitebrowser_backup"]?.map(\.referencedColumn) == ["id"])
        }
    }
}
