//
//  SQLiteColumnReorderPlanner.swift
//  TableProPluginKit
//

import Foundation

/// Builds SQLite's documented table-rebuild script for a column reorder.
///
/// SQLite has no positional `ALTER`, so the order changes by creating the table again in the wanted
/// order, copying the rows into it, dropping the original and renaming. A reorder is one shape of
/// the general rebuild, so it is expressed as one rather than carrying a second copy of the script:
/// `SQLiteTableRebuildPlanner` owns the procedure, and the ordering rules its documentation
/// records apply here unchanged.
///
/// Measured against 3.54 with a table carrying a generated column, a table `CHECK`, a `COLLATE`, a
/// `DEFAULT` containing a comma, a `DECIMAL(10,2)`, an index, a trigger, an outbound foreign key
/// and two dependent views: every one of them survives, and no `PRAGMA legacy_alter_table` is
/// needed for the rename to pass the views.
public enum SQLiteColumnReorderPlanner {
    /// Gathers what the rebuild needs from `sqlite_master` and the table's pragmas, then builds the
    /// plan. Every SQLite-derived driver answers these queries identically, so they share one
    /// implementation rather than carrying four copies that drift.
    public static func plan(
        tableName: String,
        desiredOrder: [String],
        isRunnable: Bool,
        execute: (String) async throws -> PluginQueryResult
    ) async throws -> PluginColumnReorderPlan? {
        guard let context = try await SQLiteTableRebuildPlanner.context(
            tableName: tableName, execute: execute
        ) else { return nil }
        guard context.parsed.columnNames != desiredOrder else { return nil }

        return SQLiteTableRebuildPlanner.plan(
            tableName: tableName,
            context: context,
            respecification: PluginTableRespecification(columnOrder: desiredOrder),
            /// A reorder adds no column, so nothing is ever rendered from a model here.
            renderColumn: { _ in "" },
            isRunnable: isRunnable
        )
    }

    /// The same plan from facts already gathered, with no database to ask.
    ///
    /// Published before the general rebuild planner existed, and kept at its exact signature: a
    /// plugin built against an earlier PluginKit references this symbol by name, and taking it away
    /// stops that binary loading. It delegates rather than carrying a second copy of the script.
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
        guard let parsed = SQLiteTableDDL.parse(createTableSQL: createTableSQL),
              parsed.columnNames != desiredOrder else { return nil }

        return SQLiteTableRebuildPlanner.plan(
            tableName: tableName,
            context: SQLiteTableRebuildPlanner.Context(
                parsed: parsed,
                copyableColumns: copyableColumns,
                dependentObjectSQL: dependentObjectSQL,
                autoincrementHighWaterMark: autoincrementHighWaterMark,
                foreignKeysWereOn: foreignKeysWereOn
            ),
            respecification: PluginTableRespecification(columnOrder: desiredOrder),
            renderColumn: { _ in "" },
            isRunnable: isRunnable
        )
    }

    /// A fingerprint of everything the rebuild reproduces, so a plan built before a review sheet
    /// opened can be checked against the database before it drops anything.
    public static func schemaFingerprint(
        tableName: String,
        execute: (String) async throws -> PluginQueryResult
    ) async throws -> String {
        try await SQLiteTableRebuildPlanner.schemaFingerprint(tableName: tableName, execute: execute)
    }
}
