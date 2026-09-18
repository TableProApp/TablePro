//
//  CloudflareD1PluginDriver+Triggers.swift
//  CloudflareD1DriverPlugin
//

import Foundation
import TableProPluginKit

extension CloudflareD1PluginDriver {
    var providesBulkTriggerFetch: Bool { true }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await sqliteTriggerList(table: nil)
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        let listed = try await sqliteTriggerList(table: trigger.table)
        guard let definition = listed.first(where: { $0.name == trigger.name })?.definition,
              !definition.isEmpty
        else {
            throw PluginObjectSourceError.notFound(trigger.name)
        }
        return definition
    }

    func sqliteTriggerList(table: String?) async throws -> [PluginTriggerInfo] {
        let query = SQLiteMasterQueries.triggerList(table: table, excludeNameGlob: "_cf_*")
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginTriggerInfo? in
            guard row.count >= 3, let name = row[0].asText, let sql = row[2].asText else { return nil }
            return SQLiteMasterQueries.trigger(name: name, table: row[1].asText, sql: sql)
        }
    }
}
