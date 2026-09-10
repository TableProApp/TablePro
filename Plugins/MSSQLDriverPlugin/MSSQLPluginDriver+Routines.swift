//
//  MSSQLPluginDriver+Routines.swift
//  MSSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MSSQLPluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        let resolvedSchema = effectiveSchema(schema)
        let result = try await execute(query: MSSQLObjectQueries.routineList(schema: resolvedSchema))
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let objectType = row[safe: 2]?.asText ?? ""
            let isProcedure = MSSQLObjectQueries.routineKind(forObjectType: objectType) == "PROCEDURE"
            var attributes: [PluginObjectAttribute] = []
            attributes.append(PluginObjectAttribute(label: "Object Type", value: objectType.trimmingCharacters(in: .whitespaces)))
            if row[safe: 4]?.asText == "1" {
                attributes.append(PluginObjectAttribute(label: "Encrypted", value: "YES"))
            }
            let parameters = row[safe: 5]?.asText ?? ""
            return PluginRoutineInfo(
                name: name,
                kind: isProcedure ? .procedure : .function,
                schema: row[safe: 1]?.asText ?? resolvedSchema,
                returnType: isProcedure ? nil : row[safe: 6]?.asText,
                language: "T-SQL",
                argumentSignature: "(\(parameters))",
                identity: nil,
                attributes: attributes
            )
        }
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        let resolvedSchema = effectiveSchema(routine.schema)
        let query = MSSQLObjectQueries.routineDefinition(schema: resolvedSchema, name: routine.name)
        let result = try await execute(query: query)
        guard let row = result.rows.first else {
            throw PluginObjectSourceError.notFound(routine.name)
        }
        /// sys.sql_modules.definition is NULL for WITH ENCRYPTION, and for a caller without
        /// VIEW DEFINITION. Neither means the routine is gone.
        guard let definition = row[safe: 0]?.asText, !definition.isEmpty else {
            throw PluginObjectSourceError.insufficientPrivilege(routine.name)
        }
        return definition
    }

    var providesBulkTriggerFetch: Bool { true }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await triggerList(schema: effectiveSchema(schema), table: nil)
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        let listed = try await triggerList(schema: effectiveSchema(trigger.schema), table: trigger.table)
        guard let definition = listed.first(where: { $0.name == trigger.name })?.definition,
              !definition.isEmpty
        else {
            throw PluginObjectSourceError.insufficientPrivilege(trigger.name)
        }
        return definition
    }

    /// sys.trigger_events has one row per event, so a trigger on INSERT and UPDATE arrives twice
    /// and its events are folded back together here in the order the server listed them.
    func triggerList(schema: String, table: String?) async throws -> [PluginTriggerInfo] {
        let result = try await execute(query: MSSQLObjectQueries.triggerList(schema: schema, table: table))
        var order: [String] = []
        var byKey: [String: (info: PluginTriggerInfo, events: [String])] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText else { continue }
            let owningTable = row[safe: 1]?.asText
            let key = "\(owningTable ?? "")|\(name)"
            let event = row[safe: 4]?.asText ?? ""
            if byKey[key] == nil {
                order.append(key)
                let definition = row[safe: 6]?.asText ?? ""
                byKey[key] = (
                    info: PluginTriggerInfo(
                        name: name,
                        table: owningTable,
                        schema: row[safe: 2]?.asText ?? schema,
                        timing: row[safe: 3]?.asText == "1" ? "INSTEAD OF" : "AFTER",
                        event: "",
                        orientation: "STATEMENT",
                        statement: definition,
                        definition: definition,
                        enabled: row[safe: 5]?.asText != "1",
                        attributes: []
                    ),
                    events: []
                )
            }
            if !event.isEmpty {
                byKey[key]?.events.append(event)
            }
        }
        return order.compactMap { key in
            guard let entry = byKey[key] else { return nil }
            let info = entry.info
            return PluginTriggerInfo(
                name: info.name,
                table: info.table,
                schema: info.schema,
                timing: info.timing,
                event: entry.events.joined(separator: " OR "),
                orientation: info.orientation,
                statement: info.statement,
                definition: info.definition,
                enabled: info.enabled,
                attributes: info.attributes
            )
        }
    }
}
