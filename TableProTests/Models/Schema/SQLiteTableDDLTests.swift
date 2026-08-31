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
            isRunnable: true
        )
    }

    @Test("The script follows SQLite's documented rebuild, in its order")
    func planFollowsDocumentedProcedure() throws {
        let plan = try #require(makePlan(desiredOrder: ["pid", "a", "d", "b", "c"]))
        #expect(plan.cost == .tableRebuild)
        #expect(plan.statements.first == "PRAGMA foreign_keys = off")
        #expect(plan.statements[1] == "BEGIN TRANSACTION")
        #expect(plan.statements[2].hasPrefix("CREATE TABLE \"x_tablepro_reorder\""))
        #expect(plan.statements[4] == "DROP TABLE \"x\"")
        #expect(plan.statements[5] == "ALTER TABLE \"x_tablepro_reorder\" RENAME TO \"x\"")
        #expect(plan.statements.contains("CREATE INDEX ix_x_b ON x(b)"))
        #expect(plan.statements.last == "PRAGMA foreign_keys = on")
    }

    @Test("The copy names only the columns INSERT accepts, leaving the generated one out")
    func planExcludesGeneratedColumnsFromTheCopy() throws {
        let plan = try #require(makePlan(desiredOrder: ["pid", "a", "d", "b", "c"]))
        let insert = try #require(plan.statements.first { $0.hasPrefix("INSERT INTO") })
        #expect(insert.contains("(\"a\", \"b\", \"c\", \"pid\")"))
        #expect(!insert.contains("\"d\""))
    }

    @Test("A failure part way closes the transaction it opened")
    func planCarriesItsOwnRollback() throws {
        let plan = try #require(makePlan(desiredOrder: ["pid", "a", "d", "b", "c"]))
        #expect(plan.rollbackStatements == ["ROLLBACK", "PRAGMA foreign_keys = on"])
    }

    @Test("An order that changes nothing produces no plan")
    func planRefusesAnUnchangedOrder() {
        #expect(makePlan(desiredOrder: ["a", "b", "c", "d", "pid"]) == nil)
    }
}
