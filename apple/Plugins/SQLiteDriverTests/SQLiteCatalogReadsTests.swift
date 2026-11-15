//
//  SQLiteCatalogReadsTests.swift
//  SQLiteDriverTests
//

import Foundation
import TableProPluginKit
import Testing

private actor RecordingRunner {
    private(set) var sent: [String] = []
    private var answers: [[[PluginCellValue]]]

    init(_ answers: [[[PluginCellValue]]] = []) {
        self.answers = answers
    }

    func answer(_ sql: String) -> PluginQueryResult {
        sent.append(sql)
        let rows = answers.isEmpty ? [] : answers.removeFirst()
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: rows, rowsAffected: 0, executionTime: 0)
    }

    nonisolated var run: SQLiteCatalogReads.Run {
        { await self.answer($0) }
    }
}

struct SQLiteCatalogReadsTests {
    @Test("A table's columns come from table_xinfo, with generation expressions from its CREATE statement")
    func columnsReadTableXinfoAndTheCreateStatement() async throws {
        let runner = RecordingRunner([
            [
                ["0", "id", "INTEGER", "1", nil, "1", "0"],
                ["1", "doubled", "INT", "0", nil, "0", "2"],
                ["2", "rowid_alias", "INT", "0", nil, "0", "1"],
                ["3", "n", "INT", "0", "0", "0", "0"],
            ],
            [["table", "CREATE TABLE t (id INTEGER PRIMARY KEY, doubled INT GENERATED ALWAYS AS (id * 2) VIRTUAL, n INT DEFAULT 0)"]],
        ])

        let columns = try await SQLiteCatalogReads.columns(table: "t", schema: "auth", run: runner.run)

        #expect(await runner.sent == [
            "SELECT * FROM pragma_table_xinfo('t', 'auth')",
            SQLiteTemporarySchema.definitionQuery(name: "t", types: ["table"], schema: "auth"),
        ])
        #expect(columns.map { $0.name } == ["id", "doubled", "n"])
        #expect(columns[0].isPrimaryKey)
        #expect(!columns[0].isNullable)
        #expect(columns[1].generationKind == .virtual)
        #expect(columns[1].generationExpression == "id * 2")
        #expect(columns[2].isNullable)
        #expect(columns[2].defaultValue == "0")
        #expect(columns[2].generationExpression == nil)
    }

    @Test("Check constraints are parsed from the table's own CREATE statement")
    func checkConstraintsReadTheCreateStatement() async throws {
        let runner = RecordingRunner([
            [["table", "CREATE TABLE t (a INT, CONSTRAINT positive CHECK (a > 0))"]],
        ])

        let constraints = try await SQLiteCatalogReads.checkConstraints(table: "t", schema: nil, run: runner.run)

        #expect(await runner.sent == [SQLiteTemporarySchema.definitionQuery(name: "t", types: ["table"], schema: nil)])
        #expect(constraints.map { $0.name } == ["positive"])
        #expect(constraints.map { $0.expression } == ["a > 0"])
    }

    @Test("All columns are one read joined with table_xinfo, grouped by table")
    func allColumnsIsOneRead() async throws {
        let createA = "CREATE TABLE a (id INTEGER PRIMARY KEY, g INT GENERATED ALWAYS AS (id + 1) STORED)"
        let runner = RecordingRunner([
            [
                ["a", "0", "id", "INTEGER", "1", nil, "1", "0", .text(createA)],
                ["a", "1", "g", "INT", "0", nil, "0", "3", .text(createA)],
                ["a", "2", "hidden", "INT", "0", nil, "0", "1", .text(createA)],
                ["b", "0", "label", "TEXT", "0", "'none'", "0", "0", "CREATE TABLE b (label TEXT DEFAULT 'none')"],
            ],
        ])

        let columns = try await SQLiteCatalogReads.allColumns(schema: nil, run: runner.run)

        #expect(await runner.sent == [
            """
            SELECT m.name AS tbl, p.cid, p.name, p.type, p."notnull", p.dflt_value, p.pk,
                   p.hidden, m.sql
            FROM sqlite_master m,
                 pragma_table_xinfo(m.name) p
            WHERE m.type = 'table' AND m.name NOT GLOB 'sqlite_*'
            ORDER BY m.name, p.cid
            """,
        ])
        #expect(columns["a"]?.map { $0.name } == ["id", "g"])
        #expect(columns["a"]?.last?.generationKind == .stored)
        #expect(columns["a"]?.last?.generationExpression == "id + 1")
        #expect(columns["b"]?.first?.defaultValue == "'none'")
        #expect(columns["b"]?.first?.isNullable == true)
    }

    @Test("All foreign keys are the shared grouping over one read, naming the attached database")
    func allForeignKeysUseTheSharedGrouping() async throws {
        let runner = RecordingRunner([
            [[
                "orders", "0", "0", "customers", "customer_id", "id", "NO ACTION", "CASCADE", "NONE",
                "CREATE TABLE orders (customer_id INT REFERENCES customers (id) ON DELETE CASCADE)",
            ]],
        ])

        let keys = try await SQLiteCatalogReads.allForeignKeys(schema: "auth", run: runner.run)

        #expect(await runner.sent == [SQLiteForeignKeyGrouping.schemaForeignKeysQuery(schema: "auth", excludingTableGlob: nil)])
        let key = try #require(keys["orders"]?.first)
        #expect(key.column == "customer_id")
        #expect(key.referencedTable == "customers")
        #expect(key.referencedColumn == "id")
        #expect(key.referencedSchema == "auth")
        #expect(key.onDelete == "CASCADE")
        #expect(key.onUpdate == "NO ACTION")
    }

    @Test("A table's DDL ends with a semicolon and a view's comes back as stored")
    func tableDDLTerminatesTablesOnly() async throws {
        let runner = RecordingRunner([
            [["table", "CREATE TABLE t (a INT)"]],
            [["view", "CREATE VIEW v AS SELECT 1 -- kept"]],
        ])

        #expect(try await SQLiteCatalogReads.tableDDL(table: "t", schema: nil, run: runner.run) == "CREATE TABLE t (a INT);")
        #expect(try await SQLiteCatalogReads.tableDDL(table: "v", schema: nil, run: runner.run) == "CREATE VIEW v AS SELECT 1 -- kept")
        #expect(await runner.sent == [
            SQLiteTemporarySchema.definitionQuery(name: "t", types: ["table", "view"], schema: nil),
            SQLiteTemporarySchema.definitionQuery(name: "v", types: ["table", "view"], schema: nil),
        ])
    }

    @Test("A table with no stored definition is named in the error")
    func missingTableDDLThrows() async {
        let runner = RecordingRunner()
        do {
            _ = try await SQLiteCatalogReads.tableDDL(table: "gone", schema: nil, run: runner.run)
            Issue.record("Expected an error")
        } catch let error as SQLiteCatalogReadError {
            #expect(error.pluginErrorMessage == "Failed to fetch DDL for table 'gone'")
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("A view's definition is read from the catalog of its own database")
    func viewDefinitionReadsTheAttachedCatalog() async throws {
        let runner = RecordingRunner([[["CREATE VIEW v AS SELECT 1"]]])

        let ddl = try await SQLiteCatalogReads.viewDefinition(view: "v", schema: "auth", run: runner.run)

        #expect(ddl == "CREATE VIEW v AS SELECT 1")
        #expect(await runner.sent == [
            """
            SELECT sql FROM "auth".sqlite_master
            WHERE type = 'view' AND name = 'v'
            """,
        ])
    }

    @Test("A missing view is named in the error")
    func missingViewDefinitionThrows() async {
        let runner = RecordingRunner()
        do {
            _ = try await SQLiteCatalogReads.viewDefinition(view: "gone", schema: nil, run: runner.run)
            Issue.record("Expected an error")
        } catch let error as SQLiteCatalogReadError {
            #expect(error.pluginErrorMessage == "Failed to fetch definition for view 'gone'")
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("Index DDL is each index's stored text, without the indexes SQLite made itself")
    func indexDDLKeepsStoredText() async throws {
        let runner = RecordingRunner([[["CREATE INDEX i ON t (a)", "i"], [nil, "sqlite_autoindex_t_1"]]])

        let ddl = try await SQLiteCatalogReads.indexDDL(table: "t", schema: nil, run: runner.run)

        #expect(ddl == ["CREATE INDEX i ON t (a)"])
        #expect(await runner.sent == [SQLiteTemporarySchema.indexDefinitionsQuery(table: "t", schema: nil)])
    }

    @Test("A schema's triggers carry their table, schema and stored text")
    func triggersMapTheCatalogRows() async throws {
        let sql = "CREATE TRIGGER trg AFTER INSERT ON t BEGIN SELECT 1; END"
        let runner = RecordingRunner([[[.text("trg"), "t", .text(sql)], ["short", "t"]]])

        let triggers = try await SQLiteCatalogReads.triggers(table: nil, schema: "auth", run: runner.run)

        #expect(await runner.sent == [SQLiteMasterQueries.triggerList(table: nil, schema: "auth", excludeNameGlob: nil)])
        #expect(triggers.map { $0.name } == ["trg"])
        #expect(triggers.first?.table == "t")
        #expect(triggers.first?.schema == "auth")
        #expect(triggers.first?.definition == sql)
    }

    @Test("A trigger that carries its definition is answered without a read")
    func triggerDDLUsesTheListedDefinition() async throws {
        let runner = RecordingRunner()
        let trigger = PluginTriggerInfo(
            name: "trg", table: "t", timing: "AFTER", event: "INSERT", statement: "", definition: "CREATE TRIGGER trg"
        )

        #expect(try await SQLiteCatalogReads.triggerDDL(trigger, run: runner.run) == "CREATE TRIGGER trg")
        #expect(await runner.sent.isEmpty)
    }

    @Test("A trigger without a definition is looked up among its table's triggers")
    func triggerDDLReadsItsTable() async throws {
        let sql = "CREATE TRIGGER trg AFTER INSERT ON t BEGIN SELECT 1; END"
        let runner = RecordingRunner([[[.text("trg"), "t", .text(sql)]], []])
        let trigger = PluginTriggerInfo(name: "trg", table: "t", timing: "AFTER", event: "INSERT", statement: "")

        #expect(try await SQLiteCatalogReads.triggerDDL(trigger, run: runner.run) == sql)
        #expect(await runner.sent == [SQLiteTemporarySchema.triggerListQuery(table: "t", schema: nil)])

        let missing = PluginTriggerInfo(name: "other", table: "t", timing: "AFTER", event: "INSERT", statement: "")
        await #expect(throws: PluginObjectSourceError.self) {
            try await SQLiteCatalogReads.triggerDDL(missing, run: runner.run)
        }
    }

    @Test("A trigger drop names the attached database it lives in")
    func dropTriggerStatementIsQualified() {
        #expect(SQLiteCatalogReads.dropTriggerStatement(name: "trg", schema: "auth") == "DROP TRIGGER IF EXISTS `auth`.`trg`")
        #expect(SQLiteCatalogReads.dropTriggerStatement(name: "trg", schema: nil) == "DROP TRIGGER IF EXISTS `trg`")
    }

    @Test("The driver turns foreign key checks off and on with the shared statements")
    func foreignKeyStatementsAreShared() {
        #expect(SQLiteCatalogReads.foreignKeyDisableStatements == ["PRAGMA foreign_keys = OFF"])
        #expect(SQLiteCatalogReads.foreignKeyEnableStatements == ["PRAGMA foreign_keys = ON"])
        let driver = SQLitePluginDriver(config: DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: ":memory:"))
        #expect(driver.foreignKeyDisableStatements() == SQLiteCatalogReads.foreignKeyDisableStatements)
        #expect(driver.foreignKeyEnableStatements() == SQLiteCatalogReads.foreignKeyEnableStatements)
        #expect(driver.tableDDLIncludesForeignKeys)
        #expect(driver.generateDropTriggerSQL(name: "trg", table: "t", schema: "auth") == "DROP TRIGGER IF EXISTS `auth`.`trg`")
    }
}
