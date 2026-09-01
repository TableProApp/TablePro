//
//  PostgreSQLPluginDriver+Routines.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension PostgreSQLPluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        let resolvedSchema = schema ?? currentSchema ?? "public"
        let query = PostgreSQLObjectQueries.routineList(
            schema: resolvedSchema,
            serverVersionNumber: serverVersionNumber
        )
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 1]?.asText else { return nil }
            let kind: PluginRoutineKind = row[safe: 6]?.asText == "p" ? .procedure : .function
            return PluginRoutineInfo(
                name: name,
                kind: kind,
                schema: row[safe: 2]?.asText ?? resolvedSchema,
                returnType: row[safe: 4]?.asText,
                language: row[safe: 5]?.asText,
                argumentSignature: row[safe: 3]?.asText,
                identity: row[safe: 0]?.asText,
                attributes: Self.routineAttributes(row)
            )
        }
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        let resolvedSchema = routine.schema ?? currentSchema ?? "public"
        let query: String
        if let identity = routine.identity, !identity.isEmpty, Int(identity) != nil {
            query = PostgreSQLObjectQueries.routineDefinition(identity: identity)
        } else {
            query = PostgreSQLObjectQueries.routineDefinitionByName(
                name: routine.name,
                schema: resolvedSchema,
                arguments: routine.argumentSignature
            )
        }
        let result = try await execute(query: query)
        guard let ddl = result.rows.first?[safe: 0]?.asText, !ddl.isEmpty else {
            throw PluginObjectSourceError.notFound(routine.name)
        }
        return ddl
    }

    var providesBulkTriggerFetch: Bool { true }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        let resolvedSchema = schema ?? currentSchema ?? "public"
        let query = PostgreSQLObjectQueries.triggerList(schema: resolvedSchema, table: nil)
        let result = try await execute(query: query)
        return result.rows.compactMap { Self.trigger(from: $0, fallbackSchema: resolvedSchema) }
    }

    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        let resolvedSchema = trigger.schema ?? currentSchema ?? "public"
        let query = PostgreSQLObjectQueries.triggerList(schema: resolvedSchema, table: trigger.table)
        let result = try await execute(query: query)
        let match = result.rows
            .compactMap { Self.trigger(from: $0, fallbackSchema: resolvedSchema) }
            .first { $0.name == trigger.name }
        guard let definition = match?.definition, !definition.isEmpty else {
            throw PluginObjectSourceError.notFound(trigger.name)
        }
        return definition
    }

    static func trigger(from row: [PluginCellValue], fallbackSchema: String) -> PluginTriggerInfo? {
        guard let name = row[safe: 0]?.asText,
              let definition = row[safe: 7]?.asText
        else { return nil }
        var attributes: [PluginObjectAttribute] = []
        if let owner = row[safe: 8]?.asText, !owner.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Owner", value: owner))
        }
        return PluginTriggerInfo(
            name: name,
            table: row[safe: 1]?.asText,
            schema: row[safe: 2]?.asText ?? fallbackSchema,
            timing: row[safe: 3]?.asText ?? "",
            event: row[safe: 4]?.asText ?? "",
            orientation: row[safe: 5]?.asText,
            statement: definition,
            definition: definition,
            enabled: row[safe: 6]?.asText == "t",
            attributes: attributes
        )
    }

    private static func routineAttributes(_ row: [PluginCellValue]) -> [PluginObjectAttribute] {
        var attributes: [PluginObjectAttribute] = []
        if let volatility = row[safe: 7]?.asText, !volatility.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Volatility", value: volatility))
        }
        if let security = row[safe: 8]?.asText, !security.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Security", value: security))
        }
        if let owner = row[safe: 9]?.asText, !owner.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Owner", value: owner))
        }
        return attributes
    }
}
