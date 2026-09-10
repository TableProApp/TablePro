//
//  OraclePluginDriver+Routines.swift
//  OracleDriverPlugin
//

import Foundation
import TableProPluginKit

extension OraclePluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        let resolvedSchema = routineSchema(schema)
        let result = try await execute(query: OracleObjectQueries.routineList(schema: resolvedSchema))
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let objectType = (row[safe: 2]?.asText ?? "").uppercased()
            var attributes: [PluginObjectAttribute] = []
            if let status = row[safe: 3]?.asText, !status.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Status", value: status))
            }
            return PluginRoutineInfo(
                name: name,
                kind: objectType == "PROCEDURE" ? .procedure : .function,
                schema: row[safe: 1]?.asText ?? resolvedSchema,
                returnType: nil,
                language: "PL/SQL",
                argumentSignature: nil,
                identity: objectType,
                attributes: attributes
            )
        }
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        let resolvedSchema = routineSchema(routine.schema)
        let type = routine.kind == .procedure ? "PROCEDURE" : "FUNCTION"
        let query = OracleObjectQueries.routineSource(
            schema: resolvedSchema,
            name: routine.name,
            type: type
        )
        let result = try await execute(query: query)
        /// ALL_SOURCE holds one line per row and returns no rows at all when the caller cannot see
        /// the object, which is a privilege answer rather than a missing one.
        guard !result.rows.isEmpty else {
            throw PluginObjectSourceError.insufficientPrivilege(routine.name)
        }
        let body = result.rows
            .compactMap { $0[safe: 0]?.asText }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw PluginObjectSourceError.insufficientPrivilege(routine.name)
        }
        return body.uppercased().hasPrefix("CREATE") ? body : "CREATE OR REPLACE \(body)"
    }

    /// False on purpose. `triggerList` scopes a whole-schema read on OWNER, the trigger's own
    /// schema, and a per-table read on TABLE_OWNER, the subject table's. Those are different
    /// questions for a trigger one schema owns on another's table, and a caller holding a bare
    /// table name cannot tell them apart, so a comparison would accept a trigger from outside its
    /// scope and miss one inside it.
    var providesBulkTriggerFetch: Bool { false }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await triggerList(schema: routineSchema(schema), table: nil)
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        let listed = try await triggerList(schema: routineSchema(trigger.schema), table: trigger.table)
        guard let definition = listed.first(where: { $0.name == trigger.name })?.definition,
              !definition.isEmpty
        else {
            throw PluginObjectSourceError.insufficientPrivilege(trigger.name)
        }
        return definition
    }

    func triggerList(schema: String, table: String?) async throws -> [PluginTriggerInfo] {
        let result = try await execute(query: OracleObjectQueries.triggerList(schema: schema, table: table))
        return result.rows.compactMap { row -> PluginTriggerInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let triggerType = row[safe: 3]?.asText ?? ""
            let definition = OracleObjectQueries.triggerDefinition(
                description: row[safe: 7]?.asText,
                body: row[safe: 8]?.asText,
                name: name
            )
            var attributes: [PluginObjectAttribute] = []
            if let whenClause = row[safe: 6]?.asText, !whenClause.isEmpty {
                attributes.append(PluginObjectAttribute(label: "When", value: whenClause))
            }
            return PluginTriggerInfo(
                name: name,
                table: row[safe: 1]?.asText,
                schema: row[safe: 2]?.asText ?? schema,
                timing: OracleObjectQueries.timing(fromTriggerType: triggerType),
                event: row[safe: 4]?.asText ?? "",
                orientation: OracleObjectQueries.orientation(fromTriggerType: triggerType),
                statement: row[safe: 8]?.asText ?? definition,
                definition: definition,
                enabled: (row[safe: 5]?.asText ?? "").uppercased() == "ENABLED",
                attributes: attributes
            )
        }
    }

    private func routineSchema(_ schema: String?) -> String {
        effectiveSchema(schema?.isEmpty == false ? schema : nil)
    }
}
