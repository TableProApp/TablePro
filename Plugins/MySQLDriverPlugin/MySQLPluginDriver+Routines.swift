//
//  MySQLPluginDriver+Routines.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MySQLPluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        let resolvedSchema = routineSchema(schema)
        let result = try await execute(query: MySQLObjectQueries.routineList(schema: resolvedSchema))
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let isProcedure = row[safe: 1]?.asText?.uppercased() == "PROCEDURE"
            let parameters = row[safe: 8]?.asText ?? ""
            var attributes: [PluginObjectAttribute] = []
            if let access = row[safe: 3]?.asText, !access.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Data Access", value: access))
            }
            if let deterministic = row[safe: 4]?.asText, !deterministic.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Deterministic", value: deterministic))
            }
            if let security = row[safe: 5]?.asText, !security.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Security", value: security))
            }
            if let definer = row[safe: 6]?.asText, !definer.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Definer", value: definer))
            }
            return PluginRoutineInfo(
                name: name,
                kind: isProcedure ? .procedure : .function,
                schema: row[safe: 7]?.asText ?? resolvedSchema,
                returnType: isProcedure ? nil : row[safe: 2]?.asText,
                language: "SQL",
                argumentSignature: "(\(parameters))",
                identity: nil,
                attributes: attributes
            )
        }
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        let resolvedSchema = routineSchema(routine.schema)
        let kind = routine.kind == .procedure ? "PROCEDURE" : "FUNCTION"
        let query = MySQLObjectQueries.routineDefinition(
            kind: kind,
            schema: resolvedSchema,
            name: routine.name
        )
        let result = try await execute(query: query)
        guard let row = result.rows.first else {
            throw PluginObjectSourceError.notFound(routine.name)
        }
        /// The server returns a NULL body rather than an error when the account lacks SHOW_ROUTINE,
        /// so reporting this as "not found" would tell the user their routine is gone.
        guard let ddl = row[safe: 2]?.asText, !ddl.isEmpty else {
            throw PluginObjectSourceError.insufficientPrivilege(routine.name)
        }
        return ddl
    }

    var providesBulkTriggerFetch: Bool { true }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await triggerList(schema: routineSchema(schema), table: nil)
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        let listed = try await triggerList(schema: routineSchema(trigger.schema), table: trigger.table)
        guard let definition = listed.first(where: { $0.name == trigger.name })?.definition,
              !definition.isEmpty
        else {
            throw PluginObjectSourceError.notFound(trigger.name)
        }
        return definition
    }

    func triggerList(schema: String, table: String?) async throws -> [PluginTriggerInfo] {
        let result = try await execute(query: MySQLObjectQueries.triggerList(schema: schema, table: table))
        return result.rows.compactMap { row -> PluginTriggerInfo? in
            guard let name = row[safe: 0]?.asText,
                  let owningTable = row[safe: 1]?.asText,
                  let timing = row[safe: 3]?.asText,
                  let event = row[safe: 4]?.asText,
                  let body = row[safe: 6]?.asText
            else { return nil }
            let resolvedSchema = row[safe: 2]?.asText ?? schema
            let orientation = row[safe: 5]?.asText
            let condition = row[safe: 7]?.asText
            let definer = row[safe: 8]?.asText
            let header = MySQLObjectQueries.triggerStatement(
                name: name,
                table: owningTable,
                schema: resolvedSchema,
                timing: timing,
                event: event,
                orientation: orientation,
                condition: condition,
                definer: definer
            )
            var attributes: [PluginObjectAttribute] = []
            if let definer, !definer.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Definer", value: definer))
            }
            if let order = row[safe: 9]?.asText, !order.isEmpty, order != "0" {
                attributes.append(PluginObjectAttribute(label: "Action Order", value: order))
            }
            return PluginTriggerInfo(
                name: name,
                table: owningTable,
                schema: resolvedSchema,
                timing: timing,
                event: event,
                orientation: orientation,
                statement: body,
                definition: "\(header)\n\(body)",
                enabled: nil,
                attributes: attributes
            )
        }
    }

    private func routineSchema(_ schema: String?) -> String {
        guard let schema, !schema.isEmpty else { return activeDatabaseName }
        return schema
    }
}
