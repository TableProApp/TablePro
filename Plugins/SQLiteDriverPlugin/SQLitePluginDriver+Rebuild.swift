//
//  SQLitePluginDriver+Rebuild.swift
//  SQLiteDriverPlugin
//

import Foundation
import TableProPluginKit

extension SQLitePluginDriver {
    /// SQLite changes a table's foreign keys by recreating the table, because its `ALTER TABLE`
    /// cannot add or drop one at any version. Measured against 3.54:
    /// `ADD CONSTRAINT … FOREIGN KEY` is a syntax error, and `DROP CONSTRAINT` on a foreign key
    /// answers "constraint may not be dropped". 3.53's `ADD`/`DROP CONSTRAINT` covers `CHECK` and
    /// `NOT NULL` only, which its changelog says in as many words.
    ///
    /// The column edits in the same save ride along rather than running as separate `ALTER`s
    /// beforehand. Two transactions would leave the column changes committed when the rebuild
    /// failed, and a column this save renames would leave the staged foreign key naming a column
    /// that no longer exists.
    func generateTableRebuildPlan(
        table: String,
        schema: String?,
        respecification: PluginTableRespecification
    ) async throws -> PluginColumnReorderPlan? {
        guard !respecification.isEmpty,
              let context = try await SQLiteTableRebuildPlanner.context(
                  tableName: table,
                  execute: { try await self.execute(query: $0) }
              ) else { return nil }

        return SQLiteTableRebuildPlanner.plan(
            tableName: table,
            context: context,
            respecification: respecification,
            renderColumn: { self.sqliteColumnDefinition($0, inlinePK: false) },
            isRunnable: true
        )
    }
}
