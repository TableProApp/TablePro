//
//  CassandraPluginDriver+Routines.swift
//  CassandraDriverPlugin
//

import Foundation
import TableProPluginKit

/// Cassandra has user-defined functions and aggregates, and triggers that are a Java class name
/// rather than a body.
public enum CassandraObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    public static func functionList(keyspace: String) -> String {
        """
        SELECT function_name, argument_names, argument_types, return_type, language, body, called_on_null_input
        FROM system_schema.functions
        WHERE keyspace_name = '\(escapeLiteral(keyspace))'
        """
    }

    public static func aggregateList(keyspace: String) -> String {
        """
        SELECT aggregate_name, argument_types, return_type, state_func, state_type, final_func
        FROM system_schema.aggregates
        WHERE keyspace_name = '\(escapeLiteral(keyspace))'
        """
    }

    public static func triggerList(keyspace: String, table: String?) -> String {
        let tablePredicate = table.map { " AND table_name = '\(escapeLiteral($0))'" } ?? ""
        return """
            SELECT trigger_name, table_name, keyspace_name, options
            FROM system_schema.triggers
            WHERE keyspace_name = '\(escapeLiteral(keyspace))'\(tablePredicate)
            ALLOW FILTERING
            """
    }

    public static func signature(argumentNames: String?, argumentTypes: String?) -> String {
        let names = list(from: argumentNames)
        let types = list(from: argumentTypes)
        guard !types.isEmpty else { return "()" }
        let parts = types.enumerated().map { index, type -> String in
            guard index < names.count, !names[index].isEmpty else { return type }
            return "\(names[index]) \(type)"
        }
        return "(\(parts.joined(separator: ", ")))"
    }

    /// The driver renders a CQL list as `['a', 'b']`, so the brackets and quotes come off before
    /// the elements can be paired up with each other.
    public static func list(from value: String?) -> [String] {
        guard let value else { return [] }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: ",").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        }
    }

    public static func functionDefinition(
        keyspace: String,
        name: String,
        signature: String,
        returnType: String?,
        language: String?,
        body: String?,
        calledOnNullInput: Bool
    ) -> String {
        let nullBehaviour = calledOnNullInput ? "CALLED ON NULL INPUT" : "RETURNS NULL ON NULL INPUT"
        return """
            CREATE OR REPLACE FUNCTION \(keyspace).\(name)\(signature)
                \(nullBehaviour)
                RETURNS \(returnType ?? "text")
                LANGUAGE \(language ?? "java")
                AS $$\(body ?? "")$$;
            """
    }
}

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
                signature: signature,
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
            let definition = """
                CREATE OR REPLACE AGGREGATE \(keyspace).\(name)\(signature)
                    SFUNC \(row[safe: 3]?.asText ?? "")
                    STYPE \(row[safe: 4]?.asText ?? "")\(row[safe: 5]?.asText.map { "\n    FINALFUNC \($0)" } ?? "");
                """
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
            let options = row[safe: 3]?.asText ?? ""
            let owningTable = row[safe: 1]?.asText
            let definition = """
                CREATE TRIGGER \(name) ON \(keyspace).\(owningTable ?? "")
                    USING \(options);
                """
            return PluginTriggerInfo(
                name: name,
                table: owningTable,
                schema: row[safe: 2]?.asText ?? keyspace,
                timing: "",
                event: "",
                orientation: nil,
                statement: options,
                definition: definition,
                enabled: nil,
                attributes: [PluginObjectAttribute(label: "Class", value: options)]
            )
        }
    }
}
