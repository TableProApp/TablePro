//
//  MySQLPluginDriver+CreationScopes.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal extension MySQLPluginDriver {
    func fetchRoutineCreationScope(_ routine: PluginRoutineInfo) async throws -> PluginStatementScope? {
        try await exportCatalog.routineCreationScope(routine)
    }

    func fetchTriggerCreationScope(_ trigger: PluginTriggerInfo) async throws -> PluginStatementScope? {
        try await exportCatalog.triggerCreationScope(trigger)
    }

    func fetchEventCreationScope(_ event: PluginEventInfo) async throws -> PluginStatementScope? {
        try await exportCatalog.eventCreationScope(event)
    }
}
