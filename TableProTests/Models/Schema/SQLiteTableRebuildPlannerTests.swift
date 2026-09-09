//
//  SQLiteTableRebuildPlannerTests.swift
//  TablePro
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SQLite Table Rebuild Planner")
struct SQLiteTableRebuildPlannerTests {
    /// The statement SQLite stores for a table carrying every trap the rewrite has to survive: a
    /// comma inside a string default, a comma inside a type's parentheses, a comma inside a
    /// generated expression, a table `CHECK`, a table `UNIQUE` and a column-level foreign key.
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

    private func context(
        sql: String? = nil,
        copyable: [String] = ["a", "b", "c", "pid"],
        dependents: [String] = ["CREATE INDEX ix_x_b ON x(b)"],
        highWaterMark: Int64? = nil,
        foreignKeysWereOn: Bool = true
    ) throws -> SQLiteTableRebuildPlanner.Context {
        let parsed = try #require(SQLiteTableDDL.parse(createTableSQL: sql ?? createSQL))
        return SQLiteTableRebuildPlanner.Context(
            parsed: parsed,
            copyableColumns: copyable,
            dependentObjectSQL: dependents,
            autoincrementHighWaterMark: highWaterMark,
            foreignKeysWereOn: foreignKeysWereOn
        )
    }

    private func plan(
        _ respecification: PluginTableRespecification,
        context: SQLiteTableRebuildPlanner.Context? = nil
    ) throws -> PluginColumnReorderPlan {
        try #require(
            SQLiteTableRebuildPlanner.plan(
                tableName: "x",
                context: context ?? (try self.context()),
                respecification: respecification,
                renderColumn: { "\"\($0.name)\" \($0.dataType)" },
                isRunnable: true
            )
        )
    }

    private let reorder = PluginTableRespecification(columnOrder: ["pid", "a", "d", "b", "c"])

    // MARK: - The documented procedure

    @Test("The script follows SQLite's documented rebuild, in its order")
    func followsDocumentedProcedure() throws {
        let plan = try plan(reorder)
        #expect(plan.cost == .tableRebuild)
        #expect(plan.statements[0].hasPrefix("CREATE TABLE \"x_tablepro_rebuild\""))
        #expect(plan.statements[1].hasPrefix("INSERT INTO \"x_tablepro_rebuild\""))
        #expect(plan.statements[2] == "DROP TABLE \"x\"")
        #expect(plan.statements[3] == "ALTER TABLE \"x_tablepro_rebuild\" RENAME TO \"x\"")
        #expect(plan.statements.contains("CREATE INDEX ix_x_b ON x(b)"))
    }

    /// The transaction is the executor's, not the plan's. Both places that run a plan open one
    /// already, so a `BEGIN` in the statements would nest inside theirs and fail.
    @Test("The plan carries no transaction control of its own")
    func carriesNoTransactionStatements() throws {
        let plan = try plan(reorder)
        #expect(plan.isTransactional)
        for keyword in ["BEGIN", "COMMIT", "ROLLBACK"] {
            #expect(!plan.statements.contains { $0.uppercased().hasPrefix(keyword) })
        }
    }

    /// Measured on SQLite 3.54 against a parent referenced with `ON DELETE CASCADE` and two child
    /// rows: with the pragma before `BEGIN` both rows survive; with it inside the transaction, or
    /// with `defer_foreign_keys = 1` instead, both are deleted. `DROP TABLE` performs an implicit
    /// `DELETE FROM`, and the pragma is silently ignored inside a transaction.
    @Test("Foreign key enforcement is turned off in the prologue, never in the statements")
    func disablesForeignKeysBeforeTheTransaction() throws {
        let plan = try plan(reorder)
        #expect(plan.prologue == ["PRAGMA foreign_keys = off"])
        #expect(!plan.statements.contains { $0.uppercased().contains("FOREIGN_KEYS") })
        #expect(!plan.scriptStatements.contains { $0.uppercased().contains("DEFER_FOREIGN_KEYS") })
    }

    /// Restored to what it was, not forced on. This driver opens connections with foreign keys off,
    /// so forcing them on turns later writes on the same connection into constraint failures.
    @Test("The foreign-key pragma is put back the way it was", arguments: [true, false])
    func restoresTheForeignKeyPragma(wasOn: Bool) throws {
        let plan = try plan(reorder, context: try context(foreignKeysWereOn: wasOn))
        #expect(plan.epilogue == ["PRAGMA foreign_keys = \(wasOn ? "on" : "off")"])
    }

    /// `DROP TABLE` takes the table's `sqlite_sequence` row with it, so without this the rebuilt
    /// table is seeded from the rows copied rather than the highest id ever issued, and the next
    /// insert reuses one that was already handed out.
    @Test("An AUTOINCREMENT table keeps its high-water mark")
    func restoresTheAutoincrementHighWaterMark() throws {
        let plan = try plan(reorder, context: try context(highWaterMark: 42))
        #expect(plan.statements.contains("UPDATE sqlite_sequence SET seq = 42 WHERE name = 'x'"))
    }

    @Test("The copy names only the columns INSERT accepts, leaving the generated one out")
    func excludesGeneratedColumnsFromTheCopy() throws {
        let insert = try #require(plan(reorder).statements.first { $0.hasPrefix("INSERT INTO") })
        #expect(insert.contains("\"a\", \"b\", \"c\""))
        #expect(!insert.contains("\"d\""))
    }

    @Test("A respecification that changes nothing produces no plan")
    func refusesAnEmptyRespecification() throws {
        #expect(
            SQLiteTableRebuildPlanner.plan(
                tableName: "x",
                context: try context(),
                respecification: PluginTableRespecification(),
                renderColumn: { _ in "" },
                isRunnable: true
            ) == nil
        )
    }

    // MARK: - Row identity

    /// Measured on 3.54: a copy that does not name `rowid` renumbers every row, so a table whose
    /// second row was deleted comes back with its third renumbered from 3 to 2. For a table with no
    /// `INTEGER PRIMARY KEY` the rowid is the only row identity the app has.
    @Test("A table with no INTEGER PRIMARY KEY carries its rowids across")
    func carriesRowidsWhenThereIsNoAlias() throws {
        let plan = try plan(
            PluginTableRespecification(columnOrder: ["b", "a"]),
            context: try context(
                sql: "CREATE TABLE x(a TEXT, b TEXT)", copyable: ["a", "b"], dependents: []
            )
        )
        let insert = try #require(plan.statements.first { $0.hasPrefix("INSERT INTO") })
        #expect(insert.contains("(rowid, \"b\", \"a\")"))
        #expect(insert.contains("SELECT rowid, \"b\", \"a\""))
    }

    /// An `INTEGER PRIMARY KEY` *is* the rowid, so naming both writes the same value twice, which
    /// SQLite accepts. Naming it anyway is the only safe rule: `INTEGER PRIMARY KEY DESC` is not an
    /// alias, its rowid runs independently, and `PRAGMA table_xinfo` reports it identically to one
    /// that is. Measured on 3.54, both ways.
    @Test("A table with an INTEGER PRIMARY KEY names rowid too, because the two cannot be told apart")
    func namesRowidEvenAlongsideAnAlias() throws {
        let insert = try #require(plan(reorder).statements.first { $0.hasPrefix("INSERT INTO") })
        #expect(insert.contains("(rowid, "))
    }

    /// Measured: `INSERT INTO w(rowid, …)` on a `WITHOUT ROWID` table fails with "table w has no
    /// column named rowid".
    @Test("A WITHOUT ROWID table has no rowid to carry")
    func omitsRowidForAWithoutRowidTable() throws {
        let plan = try plan(
            PluginTableRespecification(columnOrder: ["v", "k"]),
            context: try context(
                sql: "CREATE TABLE x(k TEXT PRIMARY KEY, v INT) WITHOUT ROWID",
                copyable: ["k", "v"], dependents: []
            )
        )
        let insert = try #require(plan.statements.first { $0.hasPrefix("INSERT INTO") })
        #expect(!insert.contains("rowid"))
        #expect(plan.statements[0].hasSuffix("WITHOUT ROWID"))
    }

    // MARK: - Verification

    /// Measured: adding a key the table's own rows already violate succeeds and commits, leaving a
    /// table whose data breaks its own constraint. The check is the only thing that catches it.
    @Test("A foreign key change is checked before the commit")
    func checksForeignKeysAfterAChange() throws {
        let plan = try plan(
            PluginTableRespecification(
                addedForeignKeys: [
                    PluginForeignKeyDefinition(
                        name: "fk", columns: ["pid"], referencedTable: "parent", referencedColumns: ["id"]
                    )
                ]
            )
        )
        #expect(plan.verifications.count == 1)
        #expect(plan.verifications[0].sql == "PRAGMA foreign_key_check(\"x\")")
    }

    /// Measured: the whole-database form aborts with "foreign key mismatch" and returns no rows at
    /// all when any key anywhere is structurally invalid, so one unrelated bad key would hide every
    /// real violation.
    @Test("The check is scoped to this table, never the whole database")
    func scopesTheForeignKeyCheck() throws {
        let plan = try plan(
            PluginTableRespecification(
                droppedForeignKeys: [
                    PluginForeignKeyDefinition(
                        name: "", columns: ["pid"], referencedTable: "parent", referencedColumns: ["id"]
                    )
                ]
            )
        )
        #expect(plan.verifications.allSatisfy { $0.sql.contains("(\"x\")") })
    }

    @Test("A change that leaves the foreign keys alone runs no check")
    func skipsTheCheckWhenForeignKeysAreUntouched() throws {
        #expect(try plan(reorder).verifications.isEmpty)
    }

    @Test("The reviewed script shows the check between the statements and the epilogue")
    func showsTheCheckInTheScript() throws {
        let plan = try plan(
            PluginTableRespecification(
                addedForeignKeys: [
                    PluginForeignKeyDefinition(
                        name: "fk", columns: ["pid"], referencedTable: "parent", referencedColumns: ["id"]
                    )
                ]
            )
        )
        let script = plan.scriptStatements
        let checkIndex = try #require(script.firstIndex { $0.hasPrefix("PRAGMA foreign_key_check") })
        let dropIndex = try #require(script.firstIndex { $0.hasPrefix("DROP TABLE") })
        #expect(dropIndex < checkIndex)
        #expect(checkIndex < script.count - 1)
    }
}
