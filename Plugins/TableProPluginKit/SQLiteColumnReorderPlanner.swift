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
    ///   - isRunnable: false for a driver whose connection cannot hold a transaction across
    ///     statements, which is every HTTP-backed one.
    public static func plan(
        tableName: String,
        createTableSQL: String,
        desiredOrder: [String],
        copyableColumns: [String],
        dependentObjectSQL: [String],
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
            "PRAGMA foreign_keys = off",
            "BEGIN TRANSACTION",
            createNew,
            "INSERT INTO \(quotedTemporary) (\(columnList)) SELECT \(columnList) FROM \(quotedOriginal)",
            "DROP TABLE \(quotedOriginal)",
            "ALTER TABLE \(quotedTemporary) RENAME TO \(quotedOriginal)"
        ]
        statements.append(contentsOf: dependentObjectSQL)
        statements.append("COMMIT")
        statements.append("PRAGMA foreign_keys = on")

        return PluginColumnReorderPlan(
            statements: statements,
            rollbackStatements: ["ROLLBACK", "PRAGMA foreign_keys = on"],
            cost: .tableRebuild,
            caveats: [
                String(localized: "A view that selects * from this table will return its columns in the new order.")
            ],
            isRunnable: isRunnable
        )
    }
}

public extension SQLiteColumnReorderPlanner {
    /// Gathers what the rebuild needs from `sqlite_master` and the table's pragma, then builds the
    /// plan. Every SQLite-derived driver answers these three queries identically, so they share one
    /// implementation rather than carrying four copies that drift.
    static func plan(
        tableName: String,
        desiredOrder: [String],
        isRunnable: Bool,
        execute: (String) async throws -> PluginQueryResult
    ) async throws -> PluginColumnReorderPlan? {
        let literal = tableName.replacingOccurrences(of: "'", with: "''")

        let createSQL = try await execute("""
            SELECT sql FROM sqlite_master WHERE type = 'table' AND name = '\(literal)'
            """).rows.first?[safe: 0]?.asText
        guard let createSQL else { return nil }

        /// `table_xinfo` reports a generated column with a non-zero `hidden`, and naming one in an
        /// `INSERT` column list fails the whole rebuild.
        let copyable = try await execute("PRAGMA table_xinfo(\(SQLiteTableDDL.quote(tableName)))")
            .rows
            .compactMap { row -> String? in
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

        return plan(
            tableName: tableName,
            createTableSQL: createSQL,
            desiredOrder: desiredOrder,
            copyableColumns: copyable,
            dependentObjectSQL: dependents,
            isRunnable: isRunnable
        )
    }
}
