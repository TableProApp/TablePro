//
//  SQLitePluginDriver+Rebuild.swift
//  SQLiteDriverPlugin
//

import Foundation
import TableProPluginKit

extension SQLitePluginDriver {
    // No ALTER TABLE adds or drops a foreign key (3.54), and the save's column edits ride along so one transaction holds both.
    func generateTableRebuildPlan(
        table: String,
        schema: String?,
        respecification: PluginTableRespecification
    ) async throws -> PluginColumnReorderPlan? {
        try Self.requireMainDatabase(schema)
        if let refusal = sqliteRespecificationRefusal(respecification) { throw SQLitePluginError.queryFailed(refusal) }
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
