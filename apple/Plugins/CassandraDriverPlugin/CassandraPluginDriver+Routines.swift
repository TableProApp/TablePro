//
//  CassandraPluginDriver+Routines.swift
//  CassandraDriverPlugin
//

import Foundation
import TableProCassandraCore
import TableProPluginKit

extension CassandraPluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        let keyspace = resolveKeyspace(schema)
        async let functions = fetchCassandraFunctions(keyspace: keyspace)
        async let aggregates = fetchCassandraAggregates(keyspace: keyspace)
        return try await functions + aggregates
    }

    // No definition means the catalog held a type or language the DDL could not carry.
    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        guard let definition = routine.definition, !definition.isEmpty else {
            throw PluginObjectSourceError.unsupported(routine.name)
        }
        return definition
    }

    // Unchecked on a live server: with no per-table read, opting in would change what Compare lists, not its speed.
    var providesBulkTriggerFetch: Bool { false }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await cassandraTriggerList(keyspace: resolveKeyspace(schema), table: nil)
    }

    // A Cassandra trigger points at a Java class the server loads, so its DDL names the class instead of a body.
    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        throw PluginObjectSourceError.unsupported(trigger.name)
    }

    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? {
        CassandraObjectQueries.dropTriggerStatement(name: name, keyspace: resolveKeyspace(schema), table: table)
    }

    private func fetchCassandraFunctions(keyspace: String) async throws -> [PluginRoutineInfo] {
        let result = try await executeCatalogQuery(CassandraObjectQueries.functionList(keyspace: keyspace))
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let argumentNames = CassandraObjectQueries.jsonList(row[safe: 1]?.asText)
            let argumentTypes = CassandraObjectQueries.jsonList(row[safe: 2]?.asText)
            let signature = argumentTypes.flatMap {
                CassandraObjectQueries.signature(argumentNames: argumentNames ?? [], argumentTypes: $0)
            }
            let language = row[safe: 4]?.asText
            let definition: String? = if let argumentNames, let argumentTypes, argumentNames.count == argumentTypes.count,
                let quotedSignature = CassandraObjectQueries.signature(
                    argumentNames: argumentNames,
                    argumentTypes: argumentTypes,
                    quotingNames: true
                ) {
                CassandraObjectQueries.functionDefinition(
                    keyspace: keyspace,
                    name: name,
                    signature: quotedSignature,
                    returnType: row[safe: 3]?.asText,
                    language: language,
                    body: row[safe: 5]?.asText,
                    calledOnNullInput: row[safe: 6]?.asText == "true"
                )
            } else {
                nil
            }
            return PluginRoutineInfo(
                name: name,
                kind: .function,
                schema: keyspace,
                returnType: row[safe: 3]?.asText,
                language: language,
                argumentSignature: signature,
                definition: definition,
                attributes: []
            )
        }
    }

    private func fetchCassandraAggregates(keyspace: String) async throws -> [PluginRoutineInfo] {
        let result = try await executeCatalogQuery(CassandraObjectQueries.aggregateList(keyspace: keyspace))
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let signature = CassandraObjectQueries.jsonList(row[safe: 1]?.asText).flatMap {
                CassandraObjectQueries.signature(argumentNames: [], argumentTypes: $0)
            }
            var attributes: [PluginObjectAttribute] = [PluginObjectAttribute(label: "Kind", value: "AGGREGATE")]
            if let stateFunction = row[safe: 3]?.asText, !stateFunction.isEmpty {
                attributes.append(PluginObjectAttribute(label: "State Function", value: stateFunction))
            }
            if let stateType = row[safe: 4]?.asText, !stateType.isEmpty {
                attributes.append(PluginObjectAttribute(label: "State Type", value: stateType))
            }
            if let finalFunction = row[safe: 5]?.asText, !finalFunction.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Final Function", value: finalFunction))
            }
            let definition = signature.flatMap { signature in
                CassandraObjectQueries.aggregateDefinition(
                    keyspace: keyspace,
                    name: name,
                    signature: signature,
                    stateFunction: row[safe: 3]?.asText,
                    stateType: row[safe: 4]?.asText,
                    finalFunction: row[safe: 5]?.asText
                )
            }
            return PluginRoutineInfo(
                name: name,
                kind: .function,
                schema: keyspace,
                returnType: row[safe: 2]?.asText,
                language: nil,
                argumentSignature: signature,
                definition: definition,
                attributes: attributes
            )
        }
    }

    func cassandraTriggerList(keyspace: String, table: String?) async throws -> [PluginTriggerInfo] {
        let result = try await executeCatalogQuery(CassandraObjectQueries.triggerList(keyspace: keyspace, table: table))
        return result.rows.compactMap { row -> PluginTriggerInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let className = CassandraObjectQueries.triggerClass(fromOptions: row[safe: 3]?.asText) ?? ""
            let owningTable = row[safe: 1]?.asText
            let definition = CassandraObjectQueries.triggerDefinition(
                keyspace: row[safe: 2]?.asText ?? keyspace,
                table: owningTable ?? "",
                name: name,
                className: className
            )
            return PluginTriggerInfo(
                name: name,
                table: owningTable,
                schema: row[safe: 2]?.asText ?? keyspace,
                timing: "",
                event: "",
                orientation: nil,
                statement: className,
                definition: definition,
                enabled: nil,
                attributes: [PluginObjectAttribute(label: "Class", value: className)]
            )
        }
    }
}
