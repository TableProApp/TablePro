//
//  PostgreSQLPluginDriver+Routines.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension PostgreSQLPluginDriver: PluginProcedureFunctionSupport {
    func fetchProcedures(schema: String?) async throws -> [PluginRoutineInfo] {
        try await fetchRoutines(schema: schema, routineType: "PROCEDURE")
    }

    func fetchFunctions(schema: String?) async throws -> [PluginRoutineInfo] {
        try await fetchRoutines(schema: schema, routineType: "FUNCTION")
    }

    func fetchProcedureDDL(name: String, schema: String?) async throws -> String {
        try await fetchRoutineDDL(name: name, schema: schema, routineType: "PROCEDURE")
    }

    func fetchFunctionDDL(name: String, schema: String?) async throws -> String {
        try await fetchRoutineDDL(name: name, schema: schema, routineType: "FUNCTION")
    }

    private func fetchRoutines(schema: String?, routineType: String) async throws -> [PluginRoutineInfo] {
        let schemaLiteral = escapeStringLiteral(schema ?? currentSchema ?? "public")
        let typeLiteral = escapeStringLiteral(routineType)
        let query = """
            SELECT r.routine_name, r.data_type, r.external_language
            FROM information_schema.routines r
            JOIN pg_proc p ON p.proname = r.routine_name
            JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = r.routine_schema
            WHERE r.routine_schema = '\(schemaLiteral)'
              AND r.routine_type = '\(typeLiteral)'
              AND NOT EXISTS (
                SELECT 1 FROM pg_depend d
                WHERE d.objid = p.oid AND d.deptype = 'e'
              )
            ORDER BY r.routine_name
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            return PluginRoutineInfo(
                name: name,
                returnType: row[safe: 1]?.asText,
                language: row[safe: 2]?.asText
            )
        }
    }

    private func fetchRoutineDDL(name: String, schema: String?, routineType: String) async throws -> String {
        let schemaLiteral = escapeStringLiteral(schema ?? currentSchema ?? "public")
        let nameLiteral = escapeStringLiteral(name)
        let typeLiteral = escapeStringLiteral(routineType)
        let query = """
            SELECT pg_get_functiondef(p.oid)
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            JOIN information_schema.routines r
              ON r.specific_name = p.proname || '_' || p.oid
            WHERE n.nspname = '\(schemaLiteral)'
              AND p.proname = '\(nameLiteral)'
              AND r.routine_type = '\(typeLiteral)'
            LIMIT 1
            """
        let result = try await execute(query: query)
        guard let ddl = result.rows.first?[safe: 0]?.asText else {
            throw NSError(
                domain: "PostgreSQLDriverPlugin",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "DDL not found for \(routineType.lowercased()) '\(name)'"]
            )
        }
        return ddl
    }
}
