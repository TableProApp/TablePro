//
//  ClickHousePluginDriver+Routines.swift
//  ClickHouseDriverPlugin
//

import Foundation
import TableProPluginKit

/// ClickHouse has user-defined functions and no procedures or triggers, so only the Functions
/// section appears.
nonisolated public enum ClickHouseObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    public static func quoteIdentifier(_ value: String) -> String {
        clickHouseQuotedIdentifier(value)
    }

    /// `origin` separates the server's own catalogue of built-ins from what a user created. Without
    /// it the list is every ClickHouse function that exists, which is thousands of rows.
    public static let functionList = """
        SELECT name, origin, is_aggregate, create_query
        FROM system.functions
        WHERE origin != 'System'
        ORDER BY name
        """

    /// 21.10 has `CREATE FUNCTION` and `create_query` but no `origin`. A built-in has no
    /// `create_query`, so the SQL functions a user created are the ones that do.
    public static let functionListWithoutOrigin = """
        SELECT name, '' AS origin, is_aggregate, create_query
        FROM system.functions
        WHERE create_query != ''
        ORDER BY name
        """

    /// ClickHouse has no `SHOW CREATE FUNCTION`: every version answers it with a syntax error.
    /// `create_query` is the definition of a SQL function and empty for an executable one, which
    /// lives in the server's configuration.
    public static func functionDefinition(name: String) -> String {
        "SELECT create_query FROM system.functions WHERE name = '\(escapeLiteral(name))'"
    }
}

nonisolated extension ClickHousePluginDriver {
    /// A server without `system.functions.create_query` (21.8 and older) predates
    /// `CREATE FUNCTION`, so it has no user-defined function to list.
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        let profile = serverProfile
        guard profile.hasFunctionCreateQuery else { return [] }
        let query = profile.hasFunctionOrigin
            ? ClickHouseObjectQueries.functionList
            : ClickHouseObjectQueries.functionListWithoutOrigin
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 0]?.asText, !name.isEmpty else { return nil }
            var attributes: [PluginObjectAttribute] = []
            if let origin = row[safe: 1]?.asText, !origin.isEmpty {
                attributes.append(PluginObjectAttribute(label: "Origin", value: origin))
            }
            if row[safe: 2]?.asText == "1" {
                attributes.append(PluginObjectAttribute(label: "Aggregate", value: "YES"))
            }
            return PluginRoutineInfo(
                name: name,
                kind: .function,
                schema: nil,
                returnType: nil,
                language: "SQL",
                argumentSignature: nil,
                identity: nil,
                definition: row[safe: 3]?.asText,
                attributes: attributes
            )
        }
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        if let cached = routine.definition, !cached.isEmpty { return cached }
        let result = try await execute(query: ClickHouseObjectQueries.functionDefinition(name: routine.name))
        guard let ddl = result.rows.first?[safe: 0]?.asText, !ddl.isEmpty else {
            throw PluginObjectSourceError.notFound(routine.name)
        }
        return ddl
    }
}
