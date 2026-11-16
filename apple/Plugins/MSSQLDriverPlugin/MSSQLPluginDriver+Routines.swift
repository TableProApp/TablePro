//
//  MSSQLPluginDriver+Routines.swift
//  MSSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MSSQLPluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        try await exportCatalog.fetchRoutines(schema: schema)
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        try await exportCatalog.fetchRoutineDDL(routine)
    }

    func generateDropRoutineSQL(name: String, signature: String?, schema: String?, isFunction: Bool) -> String? {
        exportCatalog.generateDropRoutineSQL(name: name, signature: signature, schema: schema, isFunction: isFunction)
    }

    var providesBulkTriggerFetch: Bool { true }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await exportCatalog.fetchAllTriggers(schema: schema)
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        try await exportCatalog.fetchTriggerDDL(trigger)
    }
}
