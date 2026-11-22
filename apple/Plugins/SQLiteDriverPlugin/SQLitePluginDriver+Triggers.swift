//
//  SQLitePluginDriver+Triggers.swift
//  SQLiteDriverPlugin
//

import Foundation
import TableProPluginKit

nonisolated extension SQLitePluginDriver {
    var providesBulkTriggerFetch: Bool { true }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await SQLiteCatalogReads.triggers(table: nil, schema: schema, run: catalogRun)
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        try await SQLiteCatalogReads.triggerDDL(trigger, run: catalogRun)
    }
}
