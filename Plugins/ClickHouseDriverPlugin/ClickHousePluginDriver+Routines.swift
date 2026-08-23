//
//  ClickHousePluginDriver+Routines.swift
//  ClickHouseDriverPlugin
//

import Foundation
import TableProPluginKit

/// ClickHouse has user-defined functions and no procedures or triggers, so only the Functions
/// section appears.
public enum ClickHouseObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    public static func quoteIdentifier(_ value: String) -> String {
        "`\(value.replacingOccurrences(of: "`", with: "``"))`"
    }

    /// `origin` separates the server's own catalogue of built-ins from what a user created. Without
    /// it the list is every ClickHouse function that exists, which is thousands of rows.
    public static let functionList = """
        SELECT name, origin, is_aggregate, create_query
        FROM system.functions
        WHERE origin != 'System'
        ORDER BY name
        """

    /// system.functions.create_query is documented as obsolete and is empty on several versions,
    /// so it is the fallback rather than the source.
    public static func functionDefinition(name: String) -> String {
        "SHOW CREATE FUNCTION \(quoteIdentifier(name))"
    }
}

extension ClickHousePluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        let result = try await execute(query: ClickHouseObjectQueries.functionList)
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
