//
//  MySQLPluginDriver+CreationScopes.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProMySQLCore
import TableProPluginKit

internal extension MySQLPluginDriver {
    func fetchRoutineCreationScope(_ routine: PluginRoutineInfo) async throws -> PluginStatementScope? {
        guard !flavor.isDatabend, serverHasInformationSchema else { return nil }
        let exactSchema = await schemaNamesAreCaseSensitive()
        let query = MySQLObjectQueries.routineCreationSettings(
            schema: routineSchema(routine.schema),
            name: routine.name,
            kind: routine.kind == .procedure ? "PROCEDURE" : "FUNCTION",
            exactSchema: exactSchema
        )
        let row = try await creationSettingsRow(query, named: routine.name)
        return Self.creationScope(sqlMode: row?[safe: 1]?.asText, timeZone: nil)
    }

    func fetchTriggerCreationScope(_ trigger: PluginTriggerInfo) async throws -> PluginStatementScope? {
        guard !flavor.isDatabend, holdsForServer(MySQLServerVersion.hasTriggerCatalog(banner:flavor:)) else {
            return nil
        }
        let query = MySQLObjectQueries.triggerCreationSettings(schema: routineSchema(trigger.schema), name: trigger.name)
        let row = try await creationSettingsRow(query, named: trigger.name)
        return Self.creationScope(sqlMode: row?[safe: 1]?.asText, timeZone: nil)
    }

    func fetchEventCreationScope(_ event: PluginEventInfo) async throws -> PluginStatementScope? {
        guard !flavor.isDatabend, holdsForServer(MySQLServerVersion.hasPartitionAndEventCatalogs(banner:flavor:)) else {
            return nil
        }
        let exactSchema = await schemaNamesAreCaseSensitive()
        let query = MySQLObjectQueries.eventCreationSettings(
            schema: effectiveSchema(event.schema),
            name: event.name,
            exactSchema: exactSchema
        )
        let row = try await creationSettingsRow(query, named: event.name)
        return Self.creationScope(sqlMode: row?[safe: 1]?.asText, timeZone: row?[safe: 2]?.asText)
    }

    /// Nil when the catalog has no row for the object, or no recorded mode.
    static func creationScope(sqlMode: String?, timeZone: String?) -> PluginStatementScope? {
        guard let sqlMode, let settings = MySQLCreationSettings(sqlMode: sqlMode, timeZone: timeZone) else { return nil }
        return PluginStatementScope(opening: settings.opening, closing: settings.closing)
    }

    private func creationSettingsRow(_ query: String, named name: String) async throws -> [PluginCellValue]? {
        let result = try await execute(ownStatement: query)
        return result.rows.first { $0[safe: 0]?.asText == name }
    }
}
