//
//  MySQLPluginDriver+Routines.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MySQLPluginDriver: PluginProcedureFunctionSupport {
    func fetchProcedures(schema: String?) async throws -> [PluginRoutineInfo] {
        try await fetchRoutines(routineType: "PROCEDURE")
    }

    func fetchFunctions(schema: String?) async throws -> [PluginRoutineInfo] {
        try await fetchRoutines(routineType: "FUNCTION")
    }

    func fetchProcedureDDL(name: String, schema: String?) async throws -> String {
        try await fetchRoutineDDL(name: name, kind: "PROCEDURE")
    }

    func fetchFunctionDDL(name: String, schema: String?) async throws -> String {
        try await fetchRoutineDDL(name: name, kind: "FUNCTION")
    }

    private func fetchRoutines(routineType: String) async throws -> [PluginRoutineInfo] {
        let typeLiteral = escapeStringLiteral(routineType)
        let query = """
            SELECT routine_name, data_type
            FROM information_schema.routines
            WHERE routine_schema = DATABASE()
              AND routine_type = '\(typeLiteral)'
            ORDER BY routine_name
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            return PluginRoutineInfo(
                name: name,
                returnType: row[safe: 1]?.asText,
                language: "SQL"
            )
        }
    }

    private func fetchRoutineDDL(name: String, kind: String) async throws -> String {
        let quoted = quoteIdentifier(name)
        let result = try await execute(query: "SHOW CREATE \(kind) \(quoted)")
        guard let row = result.rows.first else {
            throw NSError(
                domain: "MySQLDriverPlugin",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "DDL not found for \(kind.lowercased()) '\(name)'"]
            )
        }
        if let ddl = row[safe: 2]?.asText, !ddl.isEmpty {
            return ddl
        }
        throw NSError(
            domain: "MySQLDriverPlugin",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "DDL body missing for \(kind.lowercased()) '\(name)'"]
        )
    }
}
