//
//  SQLiteTableRebuildPlanner.swift
//  TableProPluginKit
//

import Foundation

/// Builds SQLite's documented table-rebuild script.
///
/// SQLite's `ALTER TABLE` can rename a table, rename a column, add a column, drop a column, and
/// since 3.53 add or drop a `CHECK` or `NOT NULL`. Everything else changes by creating the table
/// again the way it should be, copying the rows into it, dropping the original and renaming. That
/// is the procedure SQLite's own `ALTER TABLE` documentation prescribes, in its order, and it is
/// shared by every SQLite-derived driver.
///
/// Three details in that order are load bearing, each measured against 3.54:
///
/// `PRAGMA foreign_keys = off` runs **before** the transaction opens, never inside it. `DROP TABLE`
/// performs an implicit `DELETE FROM`, which fires `ON DELETE CASCADE` on every table referencing
/// this one, and the pragma is silently ignored inside a transaction. Measured on a parent with two
/// cascading children: pragma first leaves both rows, pragma inside the transaction leaves none,
/// and `PRAGMA defer_foreign_keys = 1` leaves none either, because deferring enforcement does not
/// stop the implicit delete. DB Browser for SQLite shipped that data loss.
///
/// The copy names `rowid` explicitly, on every rowid table. A column list without it renumbers
/// every row, because the new table assigns its own; measured, a table whose second row was deleted
/// came back with its third row renumbered from 3 to 2. Where the table has no `INTEGER PRIMARY
/// KEY` the rowid is the only row identity the app has, so renumbering silently repoints an open
/// grid's selection and its pending edits. A `WITHOUT ROWID` table has no rowid and is copied
/// without one.
///
/// A change to the foreign keys ends in `PRAGMA foreign_key_check`, scoped to this table. Adding a
/// key that the table's own rows violate otherwise succeeds and commits, leaving a table whose data
/// breaks its own constraint. Scoped to this table because the whole-database form cannot be
/// trusted: measured, it aborts with "foreign key mismatch" and returns no rows at all when any key
/// anywhere in the database is structurally invalid, so one unrelated bad key hides every real
/// violation.
///
/// That one check answers both ways a new key can be wrong, which is why the plan asks SQLite
/// rather than reimplementing its rules. A key whose rows have no matching parent comes back as
/// rows. A key whose parent columns are not a primary key or a unique index raises "foreign key
/// mismatch" instead, measured, and inside a transaction as well; SQLite accepts such a key at
/// `CREATE TABLE` while enforcement is off and only fails much later, on an unrelated write.
public enum SQLiteTableRebuildPlanner {
    /// What a rebuild of one table needs to know, gathered in one pass.
    ///
    /// Every SQLite-derived driver answers these queries identically, so they share one
    /// implementation rather than carrying a copy each.
    public struct Context: Sendable {
        public let parsed: SQLiteTableDDL.Parsed
        /// The columns `INSERT` may name, by their current names. A generated column is absent:
        /// `INSERT` refuses one, so listing it fails the whole rebuild.
        public let copyableColumns: [String]
        /// The `CREATE INDEX` and `CREATE TRIGGER` statements `DROP TABLE` takes with it.
        public let dependentObjectSQL: [String]
        /// The table's `sqlite_sequence` value, for an `AUTOINCREMENT` table. Nil for every other.
        public let autoincrementHighWaterMark: Int64?
        /// What `PRAGMA foreign_keys` read before the rebuild, so the epilogue puts it back rather
        /// than forcing it on.
        public let foreignKeysWereOn: Bool

        /// What `PRAGMA legacy_alter_table` read before the rebuild. The plan sets it both ways and
        /// it survives the commit, so the epilogue has to put the connection back as it found it.
        public let legacyAlterTableWasOn: Bool

        /// One statement per dependent view and per table carrying a trigger, which compiles that
        /// object's body without running it. Run after the column `ALTER`s so an object the edit
        /// broke fails the transaction instead of being committed broken.
        public let dependentValidationSQL: [String]

        public init(
            parsed: SQLiteTableDDL.Parsed,
            copyableColumns: [String],
            dependentObjectSQL: [String],
            autoincrementHighWaterMark: Int64?,
            foreignKeysWereOn: Bool,
            legacyAlterTableWasOn: Bool = true,
            dependentValidationSQL: [String] = []
        ) {
            self.parsed = parsed
            self.copyableColumns = copyableColumns
            self.dependentObjectSQL = dependentObjectSQL
            self.autoincrementHighWaterMark = autoincrementHighWaterMark
            self.foreignKeysWereOn = foreignKeysWereOn
            self.legacyAlterTableWasOn = legacyAlterTableWasOn
            self.dependentValidationSQL = dependentValidationSQL
        }
    }

    /// The columns SQLite reserves as an alias for the rowid. A table that defines one of these as
    /// a real column shadows the alias, so the copy cannot name it.
    private static let rowidAliases: Set<String> = ["ROWID", "OID", "_ROWID_"]

    public static func plan(
        tableName: String,
        context: Context,
        respecification: PluginTableRespecification,
        renderColumn: (PluginColumnDefinition) -> String,
        isRunnable: Bool
    ) -> PluginColumnReorderPlan? {
        guard !respecification.isEmpty else { return nil }

        /// A rename and a drop are left out of the new definition on purpose: each runs as its own
        /// `ALTER TABLE` after the rebuild, which is the only thing that carries the change into
        /// every index, trigger and view. So the new table is built under the columns' CURRENT
        /// names, and anything the save expressed in FINAL names is mapped back.
        let toCurrentName = respecification.renamedColumns.reduce(into: [String: String]()) {
            $0[$1.value.lowercased()] = $1.key
        }
        guard let respecified = SQLiteTableDDL.respecified(
            context.parsed,
            tableName: temporaryName(for: tableName),
            respecification: respecification.namedAsBuilt(using: toCurrentName),
            renderColumn: renderColumn
        ) else { return nil }

        let quotedOriginal = SQLiteTableDDL.quote(tableName)
        let quotedTemporary = SQLiteTableDDL.quote(temporaryName(for: tableName))

        let copyable = Set(context.copyableColumns.map { $0.lowercased() })
        let carried = respecified.carriedColumns.filter { copyable.contains($0.sourceName.lowercased()) }

        /// Every column the engine reports must be carried or explicitly dropped.
        ///
        /// A column the parser did not recognise is absent from `carriedColumns`, so the rebuilt
        /// table would still declare it while the `INSERT` never named it, replacing every value
        /// with NULL. Refusing here turns any gap between what the engine reports and what the
        /// parser understood into a failure to plan rather than silent data loss.
        let dropped = Set(respecification.droppedColumns.map { $0.lowercased() })
        let accountedFor = Set(carried.map { $0.sourceName.lowercased() }).union(dropped)
        guard copyable.isSubset(of: accountedFor) else { return nil }
        var targetColumns = carried.map { SQLiteTableDDL.quote($0.name) }
        var sourceColumns = carried.map { SQLiteTableDDL.quote($0.sourceName) }

        if carriesRowid(context: context, respecified: respecified, respecification: respecification) {
            targetColumns.insert("rowid", at: 0)
            sourceColumns.insert("rowid", at: 0)
        }
        guard !targetColumns.isEmpty else { return nil }

        /// `legacy_alter_table` is on for the table rename and off for the column ones, and both
        /// settings are load bearing. Measured on 3.54: at 0 the `RENAME TO` fails with "error in
        /// view v: no such table: main.t", because the view still points at the table the rebuild
        /// just dropped; at 1 a later `DROP COLUMN` silently leaves a dependent trigger or view
        /// broken instead of refusing. Relying on the connection's inherited value is not an
        /// option either way: Apple's libsqlite3 defaults it to 1 and upstream defaults it to 0.
        var statements = [
            "PRAGMA legacy_alter_table = on",
            respecified.createTableSQL,
            """
            INSERT INTO \(quotedTemporary) (\(targetColumns.joined(separator: ", "))) \
            SELECT \(sourceColumns.joined(separator: ", ")) FROM \(quotedOriginal)
            """,
            "DROP TABLE \(quotedOriginal)",
            "ALTER TABLE \(quotedTemporary) RENAME TO \(quotedOriginal)"
        ]

        /// `DROP TABLE` takes the table's `sqlite_sequence` row with it, so the rebuilt table is
        /// seeded from the rows that were copied rather than from the highest id ever issued.
        /// Measured: a table whose last row was deleted comes back one lower and the next insert
        /// reuses an id that was already handed out, which is the one thing `AUTOINCREMENT`
        /// promises will not happen.
        if let highWaterMark = context.autoincrementHighWaterMark {
            statements.append("""
                UPDATE sqlite_sequence SET seq = \(highWaterMark) WHERE name = '\(escapeLiteral(tableName))'
                """)
        }
        statements.append(contentsOf: context.dependentObjectSQL)

        /// Now the edits only `ALTER TABLE` can make correctly. SQLite rewrites the column's name
        /// through every index, trigger and view itself, which is why they run here rather than
        /// inside the new definition. Off for `legacy_alter_table`, or a drop that breaks a
        /// dependent succeeds silently.
        if !respecification.renamedColumns.isEmpty || !respecification.droppedColumns.isEmpty {
            statements.append("PRAGMA legacy_alter_table = off")
        }
        for (from, to) in respecification.renamedColumns.sorted(by: { $0.key < $1.key }) {
            statements.append(
                """
                ALTER TABLE \(quotedOriginal) RENAME COLUMN \(SQLiteTableDDL.quote(from)) \
                TO \(SQLiteTableDDL.quote(to))
                """
            )
        }
        for column in respecification.droppedColumns.sorted() {
            statements.append("ALTER TABLE \(quotedOriginal) DROP COLUMN \(SQLiteTableDDL.quote(column))")
        }

        /// Compiling each dependent object's body catches what the `ALTER`s do not refuse. Measured:
        /// a trigger on ANOTHER table that inserts a positional row into this one keeps compiling
        /// past a dropped column until its body is prepared, and a view declared with an explicit
        /// column list breaks on the count. Both commit silently otherwise.
        if !respecification.droppedColumns.isEmpty {
            statements.append(contentsOf: context.dependentValidationSQL)
        }

        var caveats = respecified.caveats
        /// A plan TablePro cannot run is handed to the user as a script, and an editor's Run All
        /// treats the check's rows as an ordinary result rather than a refusal. The check still
        /// reports the problem; nothing stops the commit but the person reading it.
        if !isRunnable, respecification.touchesForeignKeys {
            caveats.append(
                String(
                    localized: """
                        Read the foreign key check at the end of this script before committing. Run \
                        in an editor it reports the rows that break the new key, but it does not \
                        stop the script.
                        """
                )
            )
        }
        /// A type change is a data migration, not a metadata edit: the copy re-applies the new
        /// column's affinity to every value. Measured on 3.54, TEXT '007' copied into an INTEGER
        /// column becomes 7, and there is no undo.
        if respecification.retypesAColumn {
            caveats.append(
                String(
                    localized: """
                        Changing a column's type re-reads every value in it. Text that looks like a \
                        number becomes one, so '007' is stored as 7.
                        """
                )
            )
        }
        if respecification.columnOrder != nil {
            caveats.append(
                String(localized: "A view that selects * from this table will return its columns in the new order.")
            )
        }

        return PluginColumnReorderPlan(
            statements: statements,
            prologue: ["PRAGMA foreign_keys = off"],
            epilogue: [
                "PRAGMA legacy_alter_table = \(context.legacyAlterTableWasOn ? "on" : "off")",
                "PRAGMA foreign_keys = \(context.foreignKeysWereOn ? "on" : "off")"
            ],
            isTransactional: true,
            cost: .tableRebuild,
            caveats: caveats,
            isRunnable: isRunnable,
            verifications: respecification.touchesForeignKeys ? [foreignKeyCheck(on: quotedOriginal)] : []
        )
    }

    private static func foreignKeyCheck(on quotedTable: String) -> PluginPlanVerification {
        PluginPlanVerification(
            sql: "PRAGMA foreign_key_check(\(quotedTable))",
            failureMessageFormat: String(
                localized: """
                    %lld rows do not match the foreign keys this change asks for, so nothing was \
                    changed. Correct or remove those rows, then try again.
                    """
            )
        )
    }

    /// The name the rebuilt table is created under before it takes the original's place.
    public static func temporaryName(for tableName: String) -> String {
        "\(tableName)_tablepro_rebuild"
    }

    internal static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    /// Whether the copy names `rowid`, which every rowid table needs and no other table can accept.
    ///
    /// Named even when the table has an `INTEGER PRIMARY KEY`, which *is* the rowid and would carry
    /// it anyway. Measured on 3.54: naming both writes the same value twice and is accepted, while
    /// deciding not to name it cannot be done safely, because `INTEGER PRIMARY KEY DESC` is **not**
    /// an alias (its rowid runs independently) and `PRAGMA table_xinfo` reports it identically to
    /// one that is. Skipping the copy on that table renumbers every row.
    private static func carriesRowid(
        context: Context,
        respecified: SQLiteRespecifiedTable,
        respecification: PluginTableRespecification
    ) -> Bool {
        guard SQLiteTableDDL.isRowidTable(context.parsed) else { return false }
        /// A column the save *adds* under one of these names shadows the alias in the new table just
        /// as an existing one does, so it counts here too.
        let names = respecified.carriedColumns.flatMap { [$0.name, $0.sourceName] }
            + respecification.addedColumns.map(\.name)
        return !names.contains { rowidAliases.contains($0.uppercased()) }
    }
}

public extension SQLiteTableRebuildPlanner {
    /// Gathers what a rebuild of `tableName` needs from `sqlite_master` and the table's pragmas.
    ///
    /// Nil when the stored statement is one a rebuild would destroy rather than reproduce: a
    /// virtual table, whose module arguments parse exactly like a column list, or a
    /// `CREATE TABLE … AS SELECT`, which has no column list at all.
    static func context(
        tableName: String,
        execute: (String) async throws -> PluginQueryResult
    ) async throws -> Context? {
        let literal = escapeLiteral(tableName)
        let quoted = SQLiteTableDDL.quote(tableName)

        let createSQL = try await execute("""
            SELECT sql FROM sqlite_master WHERE type = 'table' AND name = '\(literal)'
            """).rows.first?[safe: 0]?.asText
        guard let createSQL, let parsed = SQLiteTableDDL.parse(createTableSQL: createSQL) else { return nil }

        /// `table_xinfo` rather than `table_info`, which omits a generated column entirely.
        let columns = try await execute("PRAGMA table_xinfo(\(quoted))").rows
        let copyable = columns.compactMap { row -> String? in
            guard let name = row[safe: 1]?.asText else { return nil }
            let hidden = row[safe: 6]?.asText.flatMap { Int($0) } ?? 0
            return hidden == 0 ? name : nil
        }


        /// The indexes and triggers `DROP TABLE` takes with it. An auto-index backing a `UNIQUE` or
        /// `PRIMARY KEY` has no `sql` of its own and comes back with the table.
        let dependents = try await execute("""
            SELECT sql FROM sqlite_master
            WHERE tbl_name = '\(literal)' AND type IN ('index', 'trigger') AND sql IS NOT NULL
            ORDER BY type, name
            """).rows.compactMap { $0[safe: 0]?.asText }

        var highWaterMark: Int64?
        if createSQL.uppercased().contains("AUTOINCREMENT") {
            highWaterMark = try await execute("""
                SELECT seq FROM sqlite_sequence WHERE name = '\(literal)'
                """).rows.first?[safe: 0]?.asText.flatMap { Int64($0) }
        }

        let foreignKeysWereOn = (try await execute("PRAGMA foreign_keys")
            .rows.first?[safe: 0]?.asText).map { $0 == "1" || $0.lowercased() == "true" } ?? false

        let legacyAlterTableWasOn = (try await execute("PRAGMA legacy_alter_table")
            .rows.first?[safe: 0]?.asText).map { $0 == "1" || $0.lowercased() == "true" } ?? false

        return Context(
            parsed: parsed,
            copyableColumns: copyable,
            dependentObjectSQL: dependents,
            autoincrementHighWaterMark: highWaterMark,
            foreignKeysWereOn: foreignKeysWereOn,
            legacyAlterTableWasOn: legacyAlterTableWasOn,
            dependentValidationSQL: try await dependentValidationSQL(execute: execute)
        )
    }

    /// One statement per dependent object that compiles its body without running it.
    ///
    /// `EXPLAIN` prepares a statement and stops, so an object's SQL is checked against the table as
    /// it now stands and nothing runs. A view is checked by selecting from it; a trigger by
    /// preparing a write against the table it fires on, which compiles every trigger on that table.
    ///
    /// Both are needed, and neither is optional. Measured on 3.54: dropping a column leaves a view
    /// declared with an explicit column list broken on its count, and leaves a trigger on *another*
    /// table that writes a positional row into this one broken on its value count. `ALTER TABLE`
    /// reports neither, `PRAGMA foreign_key_check` cannot see either, and both commit silently.
    private static func dependentValidationSQL(
        execute: (String) async throws -> PluginQueryResult
    ) async throws -> [String] {
        let views = try await execute(
            "SELECT name FROM sqlite_master WHERE type = 'view' ORDER BY name"
        ).rows.compactMap { $0[safe: 0]?.asText }

        let triggerTables = try await execute(
            "SELECT DISTINCT tbl_name FROM sqlite_master WHERE type = 'trigger' ORDER BY tbl_name"
        ).rows.compactMap { $0[safe: 0]?.asText }

        return views.map { "EXPLAIN SELECT * FROM \(SQLiteTableDDL.quote($0))" }
            + triggerTables.flatMap { table in
                [
                    "EXPLAIN INSERT INTO \(SQLiteTableDDL.quote(table)) DEFAULT VALUES",
                    "EXPLAIN DELETE FROM \(SQLiteTableDDL.quote(table))"
                ]
            }
    }

    /// A fingerprint of everything the rebuild reproduces, so a plan built before a review sheet
    /// opened can be checked against the database before it drops anything.
    static func schemaFingerprint(
        tableName: String,
        execute: (String) async throws -> PluginQueryResult
    ) async throws -> String {
        let literal = escapeLiteral(tableName)
        return try await execute("""
            SELECT group_concat(type || ':' || name || ':' || coalesce(sql, ''), '\u{1}')
            FROM (
              SELECT type, name, sql FROM sqlite_master
              WHERE tbl_name = '\(literal)' ORDER BY type, name
            )
            """).rows.first?[safe: 0]?.asText ?? ""
    }
}
