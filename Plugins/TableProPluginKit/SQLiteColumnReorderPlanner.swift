//
//  SQLiteColumnReorderPlanner.swift
//  TableProPluginKit
//

import Foundation

/// Builds SQLite's documented table-rebuild script for a column reorder.
///
/// SQLite has no positional `ALTER`, so the order changes by creating the table again in the wanted
/// order, copying the rows into it, dropping the original and renaming. This is the procedure
/// SQLite's own `ALTER TABLE` documentation prescribes, in its order, and it is shared by every
/// SQLite-derived driver.
///
/// Measured against 3.54 with a table carrying a generated column, a table `CHECK`, a `COLLATE`, a
/// `DEFAULT` containing a comma, a `DECIMAL(10,2)`, an index, a trigger, an outbound foreign key
/// and two dependent views: every one of them survives, and no `PRAGMA legacy_alter_table` is
/// needed for the rename to pass the views.
public enum SQLiteColumnReorderPlanner {
    /// - Parameters:
    ///   - createTableSQL: the statement SQLite stored for this table, from `sqlite_master.sql`.
    ///   - copyableColumns: the columns to carry over, in the table's current order, with the
    ///     generated ones left out. `INSERT` refuses a generated column, so listing one fails the
    ///     whole rebuild.
    ///   - dependentObjectSQL: the `CREATE INDEX` and `CREATE TRIGGER` statements `DROP TABLE`
    ///     takes with it, replayed after the rename.
    ///   - autoincrementHighWaterMark: the table's `sqlite_sequence` value, for an `AUTOINCREMENT`
    ///     table. Nil for every other table.
    ///   - foreignKeysWereOn: what `PRAGMA foreign_keys` read before the rebuild, so the epilogue
    ///     puts it back rather than forcing it on.
    ///   - isRunnable: false for a driver whose connection cannot hold a transaction across
    ///     statements, which is every HTTP-backed one.
    public static func plan(
        tableName: String,
        createTableSQL: String,
        desiredOrder: [String],
        copyableColumns: [String],
        dependentObjectSQL: [String],
        autoincrementHighWaterMark: Int64?,
        foreignKeysWereOn: Bool,
        isRunnable: Bool
    ) -> PluginColumnReorderPlan? {
        guard let parsed = SQLiteTableDDL.parse(createTableSQL: createTableSQL) else { return nil }
        guard parsed.columnNames != desiredOrder else { return nil }

        let temporaryName = "\(tableName)_tablepro_reorder"
        guard let createNew = SQLiteTableDDL.reordered(parsed, to: desiredOrder, tableName: temporaryName) else {
            return nil
        }

        let quotedOriginal = SQLiteTableDDL.quote(tableName)
        let quotedTemporary = SQLiteTableDDL.quote(temporaryName)
        let columnList = copyableColumns.map(SQLiteTableDDL.quote).joined(separator: ", ")

        var statements = [
            createNew,
            "INSERT INTO \(quotedTemporary) (\(columnList)) SELECT \(columnList) FROM \(quotedOriginal)",
            "DROP TABLE \(quotedOriginal)",
            "ALTER TABLE \(quotedTemporary) RENAME TO \(quotedOriginal)"
        ]

        /// `DROP TABLE` takes the table's `sqlite_sequence` row with it, so the rebuilt table is
        /// seeded from the rows that were copied rather than from the highest id ever issued.
        /// Measured: a table whose last row was deleted comes back one lower and the next insert
        /// reuses an id that was already handed out, which is the one thing `AUTOINCREMENT`
        /// promises will not happen.
        if let highWaterMark = autoincrementHighWaterMark {
            statements.append("""
                UPDATE sqlite_sequence SET seq = \(highWaterMark) WHERE name = '\(escapeLiteral(tableName))'
                """)
        }

        statements.append(contentsOf: dependentObjectSQL)

        /// The pragma is restored to what it was rather than forced on. This driver opens
        /// connections with foreign keys off, and a user can turn them off deliberately; leaving
        /// them on afterwards turns later writes on the same connection from allowed into
        /// constraint failures.
        return PluginColumnReorderPlan(
            statements: statements,
            prologue: ["PRAGMA foreign_keys = off"],
            epilogue: ["PRAGMA foreign_keys = \(foreignKeysWereOn ? "on" : "off")"],
            isTransactional: true,
            cost: .tableRebuild,
            caveats: [
                String(localized: "A view that selects * from this table will return its columns in the new order.")
            ],
            isRunnable: isRunnable
        )
    }

    internal static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

public extension SQLiteColumnReorderPlanner {
    /// Gathers what the rebuild needs from `sqlite_master` and the table's pragmas, then builds the
    /// plan. Every SQLite-derived driver answers these queries identically, so they share one
    /// implementation rather than carrying four copies that drift.
    static func plan(
        tableName: String,
        desiredOrder: [String],
        isRunnable: Bool,
        execute: (String) async throws -> PluginQueryResult
    ) async throws -> PluginColumnReorderPlan? {
        let literal = escapeLiteral(tableName)
        let quoted = SQLiteTableDDL.quote(tableName)

        let createSQL = try await execute("""
            SELECT sql FROM sqlite_master WHERE type = 'table' AND name = '\(literal)'
            """).rows.first?[safe: 0]?.asText
        guard let createSQL else { return nil }

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

        return plan(
            tableName: tableName,
            createTableSQL: createSQL,
            desiredOrder: desiredOrder,
            copyableColumns: copyable,
            dependentObjectSQL: dependents,
            autoincrementHighWaterMark: highWaterMark,
            foreignKeysWereOn: foreignKeysWereOn,
            isRunnable: isRunnable
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
