//
//  DamengPluginDriver+Routines.swift
//  DamengDriverPlugin
//

import Foundation
import TableProPluginKit

/// DM8 publishes Oracle-compatible data dictionary views, so the shapes below match the Oracle
/// driver's. Every value goes through executeParameterized rather than into the SQL text.
extension DamengPluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        let owner = effectiveSchema(schema)
        let result = try await executeParameterized(
            query: """
                SELECT OBJECT_NAME, OWNER, OBJECT_TYPE, STATUS
                FROM ALL_OBJECTS
                WHERE OWNER = ?
                  AND OBJECT_TYPE IN ('PROCEDURE', 'FUNCTION')
                ORDER BY OBJECT_TYPE, OBJECT_NAME
                """,
            parameters: [.text(owner)]
        )
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
                schema: row[safe: 1]?.asText ?? owner,
                returnType: nil,
                language: "DMSQL",
                argumentSignature: nil,
                identity: objectType,
                attributes: attributes
            )
        }
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        let owner = effectiveSchema(routine.schema)
        let type = routine.kind == .procedure ? "PROCEDURE" : "FUNCTION"
        let result = try await executeParameterized(
            query: """
                SELECT TEXT
                FROM ALL_SOURCE
                WHERE OWNER = ? AND NAME = ? AND TYPE = ?
                ORDER BY LINE
                """,
            parameters: [.text(owner), .text(routine.name), .text(type)]
        )
        /// ALL_SOURCE returns no rows at all when the caller cannot see the object, which is a
        /// privilege answer rather than a missing one.
        let body = result.rows
            .compactMap { $0[safe: 0]?.asText }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw PluginObjectSourceError.insufficientPrivilege(routine.name)
        }
        return body.uppercased().hasPrefix("CREATE") ? body : "CREATE OR REPLACE \(body)"
    }

    /// False until the whole-schema scope is checked against a live server. This driver has no
    /// per-table trigger read, so the protocol default answers with nothing and a comparison has
    /// never listed its triggers; opting in here would change what is compared rather than only
    /// how fast it is read.
    var providesBulkTriggerFetch: Bool { false }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await damengTriggerList(schema: schema, table: nil)
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        let listed = try await damengTriggerList(schema: trigger.schema, table: trigger.table)
        guard let definition = listed.first(where: { $0.name == trigger.name })?.definition,
              !definition.isEmpty
        else {
            throw PluginObjectSourceError.insufficientPrivilege(trigger.name)
        }
        return definition
    }

    func damengTriggerList(schema: String?, table: String?) async throws -> [PluginTriggerInfo] {
        let owner = effectiveSchema(schema)
        /// A schema browse asks for the triggers this schema owns, which is OWNER. A per-table
        /// fetch asks for the triggers on that table, which is TABLE_OWNER plus TABLE_NAME.
        let scope = table == nil ? "OWNER = ?" : "TABLE_OWNER = ? AND TABLE_NAME = ?"
        var parameters: [PluginCellValue] = [.text(owner)]
        if let table { parameters.append(.text(table)) }
        let result = try await executeParameterized(
            query: """
                SELECT TRIGGER_NAME, TABLE_NAME, OWNER, TRIGGER_TYPE, TRIGGERING_EVENT,
                       STATUS, WHEN_CLAUSE, DESCRIPTION, TRIGGER_BODY
                FROM ALL_TRIGGERS
                WHERE \(scope)
                ORDER BY TABLE_NAME, TRIGGER_NAME
                """,
            parameters: parameters
        )
        return result.rows.compactMap { row -> PluginTriggerInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let triggerType = (row[safe: 3]?.asText ?? "").uppercased()
            let header = row[safe: 7]?.asText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = row[safe: 8]?.asText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let definition = [header.map { "CREATE OR REPLACE TRIGGER \($0)" }, body]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: "\n")
            var attributes: [PluginObjectAttribute] = []
            if let whenClause = row[safe: 6]?.asText, !whenClause.isEmpty {
                attributes.append(PluginObjectAttribute(label: "When", value: whenClause))
            }
            return PluginTriggerInfo(
                name: name,
                table: row[safe: 1]?.asText,
                schema: row[safe: 2]?.asText ?? owner,
                timing: triggerType.contains("INSTEAD OF") ? "INSTEAD OF"
                    : (triggerType.hasPrefix("BEFORE") ? "BEFORE" : "AFTER"),
                event: row[safe: 4]?.asText ?? "",
                orientation: triggerType.contains("EACH ROW") ? "ROW" : "STATEMENT",
                statement: body ?? definition,
                definition: definition,
                enabled: (row[safe: 5]?.asText ?? "").uppercased() == "ENABLED",
                attributes: attributes
            )
        }
    }
}
