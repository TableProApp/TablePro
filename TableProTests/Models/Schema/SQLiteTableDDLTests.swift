//
//  SQLiteTableDDLTests.swift
//  TablePro
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SQLite Table DDL")
struct SQLiteTableDDLTests {
    /// The statement SQLite stores for a table carrying every trap the splitter has to survive: a
    /// comma inside a string default, a comma inside a type's parentheses, a comma inside a
    /// generated expression, a table `CHECK` and a table `UNIQUE`.
    private let createSQL = """
        CREATE TABLE x(
          a INTEGER PRIMARY KEY,
          b TEXT NOT NULL DEFAULT 'hi, there' COLLATE NOCASE,
          c DECIMAL(10,2) CHECK (c > 0),
          d TEXT GENERATED ALWAYS AS (b || ',' || a) VIRTUAL,
          pid INTEGER REFERENCES parent(id),
          CHECK (length(b) < 100),
          UNIQUE(a, b)
        )
        """

    @Test("Every column is found, and a table constraint is not mistaken for one")
    func parseSeparatesColumnsFromTableConstraints() throws {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: createSQL))
        #expect(parsed.columnNames == ["a", "b", "c", "d", "pid"])
        #expect(parsed.entries.count == 7)
    }

    @Test("A quoted column name keeps its spelling and its commas")
    func parseHandlesQuotedIdentifiers() throws {
        let sql = "CREATE TABLE t(\"a, b\" TEXT, `c,d` INT, [e,f] INT, plain INT)"
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: sql))
        #expect(parsed.columnNames == ["a, b", "c,d", "e,f", "plain"])
    }

    @Test("A statement with no column list is refused rather than half parsed")
    func parseRefusesCreateTableAsSelect() {
        #expect(SQLiteTableDDL.parse(createTableSQL: "CREATE TABLE t AS SELECT 1") == nil)
        #expect(SQLiteTableDDL.parse(createTableSQL: "CREATE TABLE t AS SELECT (1)") == nil)
    }

    /// `sqlite_master` stores an FTS5 table as a `CREATE VIRTUAL TABLE` whose parentheses parse
    /// exactly like a column list. Rebuilding one recreates it as a plain table and drops the index
    /// and its shadow tables with the original, so it has to be refused before that.
    @Test("A virtual table is refused, whatever its module", arguments: [
        "CREATE VIRTUAL TABLE docs USING fts5(title, body)",
        "CREATE VIRTUAL TABLE t USING rtree(id, minX, maxX)",
        "CREATE VIRTUAL TABLE IF NOT EXISTS v USING fts4(a, b)"
    ])
    func parseRefusesVirtualTables(sql: String) {
        #expect(SQLiteTableDDL.parse(createTableSQL: sql) == nil)
    }

    @Test("The ordinary forms are still accepted", arguments: [
        "CREATE TABLE t(a INT)",
        "CREATE TEMP TABLE t(a INT)",
        "CREATE TEMPORARY TABLE t(a INT)",
        "CREATE TABLE IF NOT EXISTS t(a INT)",
        "CREATE TABLE \"my (odd) name\"(a INT)"
    ])
    func parseAcceptsOrdinaryTables(sql: String) {
        #expect(SQLiteTableDDL.parse(createTableSQL: sql) != nil)
    }

    @Test("Reordering moves the column definitions verbatim and leaves the constraints in place")
    func reorderMovesDefinitionsVerbatim() throws {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: createSQL))
        let sql = try #require(
            SQLiteTableDDL.reordered(parsed, to: ["pid", "a", "d", "b", "c"], tableName: "x_new")
        )
        #expect(sql.contains("DEFAULT 'hi, there' COLLATE NOCASE"))
        #expect(sql.contains("DECIMAL(10,2) CHECK (c > 0)"))
        #expect(sql.contains("GENERATED ALWAYS AS (b || ',' || a) VIRTUAL"))
        #expect(sql.contains("CHECK (length(b) < 100)"))
        #expect(sql.contains("UNIQUE(a, b)"))
        #expect(sql.hasPrefix("CREATE TABLE \"x_new\" ("))

        let reparsed = try #require(SQLiteTableDDL.parse(createTableSQL: sql))
        #expect(reparsed.columnNames == ["pid", "a", "d", "b", "c"])
    }

    @Test("Trailing table options survive the rewrite")
    func reorderKeepsTrailingOptions() throws {
        let sql = "CREATE TABLE t(a INT, b INT, PRIMARY KEY(a)) WITHOUT ROWID"
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: sql))
        let rewritten = try #require(SQLiteTableDDL.reordered(parsed, to: ["b", "a"], tableName: "t_new"))
        #expect(rewritten.hasSuffix("WITHOUT ROWID"))
    }

    @Test("An order that is not a permutation of the columns is refused")
    func reorderRefusesNonPermutation() throws {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: createSQL))
        #expect(SQLiteTableDDL.reordered(parsed, to: ["a", "b"], tableName: "x_new") == nil)
        #expect(SQLiteTableDDL.reordered(parsed, to: ["a", "b", "c", "d", "zz"], tableName: "x_new") == nil)
    }

    // MARK: - Plan

    /// Named apart from the `plan` each test binds. Shadowing it compiled here and failed on the
    /// CI toolchain with "cannot call value of non-function type", because a local declaration is
    /// in scope inside its own initializer.
    private func makePlan(desiredOrder: [String]) -> PluginColumnReorderPlan? {
        SQLiteColumnReorderPlanner.plan(
            tableName: "x",
            createTableSQL: createSQL,
            desiredOrder: desiredOrder,
            copyableColumns: ["a", "b", "c", "pid"],
            dependentObjectSQL: ["CREATE INDEX ix_x_b ON x(b)"],
            autoincrementHighWaterMark: nil,
            foreignKeysWereOn: true,
            isRunnable: true
        )
    }

    @Test("The script follows SQLite's documented rebuild, in its order")
    func planFollowsDocumentedProcedure() throws {
        let plan = try #require(makePlan(desiredOrder: ["pid", "a", "d", "b", "c"]))
        #expect(plan.cost == .tableRebuild)
        #expect(plan.statements[0].hasPrefix("CREATE TABLE \"x_tablepro_reorder\""))
        #expect(plan.statements[2] == "DROP TABLE \"x\"")
        #expect(plan.statements[3] == "ALTER TABLE \"x_tablepro_reorder\" RENAME TO \"x\"")
        #expect(plan.statements.contains("CREATE INDEX ix_x_b ON x(b)"))
    }

    /// The transaction is the executor's, not the plan's. Both places that run a plan open one
    /// already, so a `BEGIN` in the statements would nest inside theirs and fail.
    @Test("The plan carries no transaction control of its own")
    func planCarriesNoTransactionStatements() throws {
        let plan = try #require(makePlan(desiredOrder: ["pid", "a", "d", "b", "c"]))
        #expect(plan.isTransactional)
        for keyword in ["BEGIN", "COMMIT", "ROLLBACK"] {
            #expect(!plan.statements.contains { $0.uppercased().hasPrefix(keyword) })
        }
    }

    /// Restored to what it was, not forced on. This driver opens connections with foreign keys off,
    /// so forcing them on turns later writes on the same connection into constraint failures.
    @Test("The foreign-key pragma is put back the way it was", arguments: [true, false])
    func planRestoresTheForeignKeyPragma(wasOn: Bool) throws {
        let plan = try #require(SQLiteColumnReorderPlanner.plan(
            tableName: "x",
            createTableSQL: createSQL,
            desiredOrder: ["pid", "a", "d", "b", "c"],
            copyableColumns: ["a", "b", "c", "pid"],
            dependentObjectSQL: [],
            autoincrementHighWaterMark: nil,
            foreignKeysWereOn: wasOn,
            isRunnable: true
        ))
        #expect(plan.prologue == ["PRAGMA foreign_keys = off"])
        #expect(plan.epilogue == ["PRAGMA foreign_keys = \(wasOn ? "on" : "off")"])
    }

    /// `DROP TABLE` takes the table's `sqlite_sequence` row with it, so without this the rebuilt
    /// table is seeded from the rows copied rather than the highest id ever issued, and the next
    /// insert reuses one that was already handed out.
    @Test("An AUTOINCREMENT table keeps its high-water mark")
    func planRestoresTheAutoincrementHighWaterMark() throws {
        let plan = try #require(SQLiteColumnReorderPlanner.plan(
            tableName: "x",
            createTableSQL: createSQL,
            desiredOrder: ["pid", "a", "d", "b", "c"],
            copyableColumns: ["a", "b", "c", "pid"],
            dependentObjectSQL: [],
            autoincrementHighWaterMark: 42,
            foreignKeysWereOn: false,
            isRunnable: true
        ))
        #expect(plan.statements.contains("UPDATE sqlite_sequence SET seq = 42 WHERE name = 'x'"))
    }

    @Test("The copy names only the columns INSERT accepts, leaving the generated one out")
    func planExcludesGeneratedColumnsFromTheCopy() throws {
        let plan = try #require(makePlan(desiredOrder: ["pid", "a", "d", "b", "c"]))
        let insert = try #require(plan.statements.first { $0.hasPrefix("INSERT INTO") })
        #expect(insert.contains("(\"a\", \"b\", \"c\", \"pid\")"))
        #expect(!insert.contains("\"d\""))
    }

    @Test("An order that changes nothing produces no plan")
    func planRefusesAnUnchangedOrder() {
        #expect(makePlan(desiredOrder: ["a", "b", "c", "d", "pid"]) == nil)
    }
}
