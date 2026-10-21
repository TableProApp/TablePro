//
//  SQLitePluginDriver+Triggers.swift
//  SQLiteDriverPlugin
//

import Foundation
import TableProPluginKit

extension SQLitePluginDriver {
    var providesBulkTriggerFetch: Bool { true }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await sqliteTriggerList(table: nil, schema: schema)
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        let listed = try await sqliteTriggerList(table: trigger.table, schema: trigger.schema)
        guard let definition = listed.first(where: { $0.name == trigger.name })?.definition,
              !definition.isEmpty
        else {
            throw PluginObjectSourceError.notFound(trigger.name)
        }
        return definition
    }

    func sqliteTriggerList(table: String?, schema: String?) async throws -> [PluginTriggerInfo] {
        let query = SQLiteTemporarySchema.triggerListQuery(table: table, schema: schema)
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginTriggerInfo? in
            guard row.count >= 3, let name = row[0].asText, let sql = row[2].asText else { return nil }
            return SQLiteMasterQueries.trigger(name: name, table: row[1].asText, schema: schema, sql: sql)
        }
    }
}
