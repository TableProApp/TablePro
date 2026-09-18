//
//  DuckDBPluginDriver+Routines.swift
//  DuckDBDriverPlugin
//

import Foundation
import TableProPluginKit

/// DuckDB has macros where other engines have functions, and no procedures or triggers.
public enum DuckDBObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    /// duckdb_functions() also lists every built-in, so the list is restricted to macros, which are
    /// the only routines a user can define.
    public static func macroList(schema: String?) -> String {
        let schemaPredicate = schema.map { "WHERE schema_name = '\(escapeLiteral($0))'" }
            ?? "WHERE schema_name NOT IN ('system', 'pg_catalog', 'information_schema')"
        return """
            SELECT schema_name, function_name, macro_definition, parameters, function_type, internal
            FROM duckdb_functions()
            \(schemaPredicate) AND function_type IN ('macro', 'table_macro') AND NOT internal
            ORDER BY schema_name, function_name
            """
    }
}

extension DuckDBPluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        let result = try await execute(query: DuckDBObjectQueries.macroList(schema: schema))
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 1]?.asText, !name.isEmpty else { return nil }
            let parameters = row[safe: 3]?.asText ?? ""
            var attributes: [PluginObjectAttribute] = []
            if let type = row[safe: 4]?.asText, !type.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Kind", value: type))
            }
            return PluginRoutineInfo(
                name: name,
                kind: .function,
                schema: row[safe: 0]?.asText,
                returnType: nil,
                language: "SQL",
                argumentSignature: parameters.isEmpty ? nil : "(\(parameters.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))))",
                identity: nil,
                definition: row[safe: 2]?.asText,
                attributes: attributes
            )
        }
    }

    /// DuckDB keeps the parsed expression, not the CREATE MACRO text the user typed, so the
    /// definition is reconstructed and labelled as such rather than presented as original source.
    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        guard let body = routine.definition, !body.isEmpty else {
            throw PluginObjectSourceError.notFound(routine.name)
        }
        let qualified = [routine.schema, routine.name]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ".")
        let signature = routine.argumentSignature ?? "()"
        return "CREATE OR REPLACE MACRO \(qualified)\(signature) AS \(body);"
    }
}
