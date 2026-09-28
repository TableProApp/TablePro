//
//  CassandraPluginDriver+Routines.swift
//  CassandraDriverPlugin
//

import Foundation
import TableProPluginKit

extension CassandraPluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        let keyspace = resolveKeyspace(schema)
        async let functions = fetchCassandraFunctions(keyspace: keyspace)
        async let aggregates = fetchCassandraAggregates(keyspace: keyspace)
        return try await functions + aggregates
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        guard let definition = routine.definition, !definition.isEmpty else {
            throw PluginObjectSourceError.notFound(routine.name)
        }
        return definition
    }

    /// False until the whole-schema scope is checked against a live server. This driver has no
    /// per-table trigger read, so the protocol default answers with nothing and a comparison has
    /// never listed its triggers; opting in here would change what is compared rather than only
    /// how fast it is read.
    var providesBulkTriggerFetch: Bool { false }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        try await cassandraTriggerList(keyspace: resolveKeyspace(schema), table: nil)
    }

    /// A Cassandra trigger is a pointer to a Java class the server loads, so there is no body to
    /// show. The class name is presented as what it is rather than as an empty source pane.
    func fetchTriggerDDL(_ trigger: PluginTriggerInfo) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        throw PluginObjectSourceError.unsupported(trigger.name)
    }

    private func fetchCassandraFunctions(keyspace: String) async throws -> [PluginRoutineInfo] {
        let result = try await execute(query: CassandraObjectQueries.functionList(keyspace: keyspace))
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let signature = CassandraObjectQueries.signature(
                argumentNames: row[safe: 1]?.asText,
                argumentTypes: row[safe: 2]?.asText
            )
            let language = row[safe: 4]?.asText
            let definition = CassandraObjectQueries.functionDefinition(
                keyspace: keyspace,
                name: name,
                signature: CassandraObjectQueries.signature(
                    argumentNames: row[safe: 1]?.asText,
                    argumentTypes: row[safe: 2]?.asText,
                    quotingNames: true
                ),
                returnType: row[safe: 3]?.asText,
                language: language,
                body: row[safe: 5]?.asText,
                calledOnNullInput: row[safe: 6]?.asText == "true"
            )
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
        let result = try await execute(query: CassandraObjectQueries.aggregateList(keyspace: keyspace))
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let signature = CassandraObjectQueries.signature(
                argumentNames: nil,
                argumentTypes: row[safe: 1]?.asText
            )
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
            let definition = CassandraObjectQueries.aggregateDefinition(
                keyspace: keyspace,
                name: name,
                signature: signature,
                stateFunction: row[safe: 3]?.asText,
                stateType: row[safe: 4]?.asText,
                finalFunction: row[safe: 5]?.asText
            )
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
        let result = try await execute(query: CassandraObjectQueries.triggerList(keyspace: keyspace, table: table))
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
