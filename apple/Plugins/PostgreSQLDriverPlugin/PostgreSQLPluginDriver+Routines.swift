//
//  PostgreSQLPluginDriver+Routines.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension PostgreSQLPluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        try await exportCatalog.fetchRoutines(schema: schema)
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        try await exportCatalog.fetchRoutineDDL(routine)
    }

    var providesBulkTriggerFetch: Bool { true }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await exportCatalog.fetchAllTriggers(schema: schema)
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        try await exportCatalog.fetchTriggerDDL(trigger)
    }
}
