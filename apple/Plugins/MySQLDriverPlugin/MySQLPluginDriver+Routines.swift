//
//  MySQLPluginDriver+Routines.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MySQLPluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        try await exportCatalog.routines(schema: schema)
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        try await exportCatalog.routineDDL(routine)
    }

    func generateDropRoutineSQL(name: String, signature: String?, schema: String?, isFunction: Bool) -> String? {
        exportCatalog.dropRoutineStatement(name: name, schema: schema, isFunction: isFunction)
    }

    var providesBulkTriggerFetch: Bool { true }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await exportCatalog.allTriggers(schema: schema)
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        try await exportCatalog.triggerDDL(trigger)
    }
}
