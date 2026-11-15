//
//  OraclePluginDriver+Routines.swift
//  OracleDriverPlugin
//

import Foundation
import TableProPluginKit

extension OraclePluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        try await exportCatalog.fetchRoutines(schema: schema)
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        try await exportCatalog.fetchRoutineDDL(routine)
    }

    // False on purpose: a whole-schema trigger read scopes on OWNER and a per-table one on TABLE_OWNER, which differ
    // for a trigger one schema owns on another's table, so a comparison would take one from outside its scope and
    // miss one inside it.
    var providesBulkTriggerFetch: Bool { false }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await exportCatalog.fetchAllTriggers(schema: schema)
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        try await exportCatalog.fetchTriggerDDL(trigger)
    }
}
