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

        public init(
            parsed: SQLiteTableDDL.Parsed,
            copyableColumns: [String],
            dependentObjectSQL: [String],
            autoincrementHighWaterMark: Int64?,
            foreignKeysWereOn: Bool
        ) {
            self.parsed = parsed
            self.copyableColumns = copyableColumns
            self.dependentObjectSQL = dependentObjectSQL
            self.autoincrementHighWaterMark = autoincrementHighWaterMark
            self.foreignKeysWereOn = foreignKeysWereOn
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
        guard let respecified = SQLiteTableDDL.respecified(
            context.parsed,
            tableName: temporaryName(for: tableName),
            respecification: respecification,
            renderColumn: renderColumn
        ) else { return nil }

        let quotedOriginal = SQLiteTableDDL.quote(tableName)
        let quotedTemporary = SQLiteTableDDL.quote(temporaryName(for: tableName))

        let copyable = Set(context.copyableColumns.map { $0.lowercased() })
        let carried = respecified.carriedColumns.filter { copyable.contains($0.sourceName.lowercased()) }
        var targetColumns = carried.map { SQLiteTableDDL.quote($0.name) }
        var sourceColumns = carried.map { SQLiteTableDDL.quote($0.sourceName) }

        if carriesRowid(context: context, respecified: respecified) {
            targetColumns.insert("rowid", at: 0)
            sourceColumns.insert("rowid", at: 0)
        }
        guard !targetColumns.isEmpty else { return nil }

        var statements = [
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

        var caveats = respecified.caveats
        if respecification.columnOrder != nil {
            caveats.append(
                String(localized: "A view that selects * from this table will return its columns in the new order.")
            )
        }

        return PluginColumnReorderPlan(
            statements: statements,
            prologue: ["PRAGMA foreign_keys = off"],
            epilogue: ["PRAGMA foreign_keys = \(context.foreignKeysWereOn ? "on" : "off")"],
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
    private static func carriesRowid(context: Context, respecified: SQLiteRespecifiedTable) -> Bool {
        guard SQLiteTableDDL.isRowidTable(context.parsed) else { return false }
        let names = respecified.carriedColumns.flatMap { [$0.name, $0.sourceName] }
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

        return Context(
            parsed: parsed,
            copyableColumns: copyable,
            dependentObjectSQL: dependents,
            autoincrementHighWaterMark: highWaterMark,
            foreignKeysWereOn: foreignKeysWereOn
        )
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
