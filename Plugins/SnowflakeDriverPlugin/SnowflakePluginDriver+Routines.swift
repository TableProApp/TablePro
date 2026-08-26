//
//  SnowflakePluginDriver+Routines.swift
//  SnowflakeDriverPlugin
//

import Foundation
import TableProPluginKit

extension SnowflakePluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        let resolvedSchema = schema ?? currentSchema ?? "PUBLIC"
        let result = try await execute(query: SnowflakeObjectQueries.routineList(schema: resolvedSchema))
        return result.rows.compactMap { row -> PluginRoutineInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let isProcedure = row[safe: 5]?.asText?.uppercased() == "PROCEDURE"
            return PluginRoutineInfo(
                name: name,
                kind: isProcedure ? .procedure : .function,
                schema: row[safe: 1]?.asText ?? resolvedSchema,
                returnType: row[safe: 3]?.asText,
                language: row[safe: 4]?.asText,
                argumentSignature: row[safe: 2]?.asText,
                identity: row[safe: 2]?.asText,
                attributes: []
            )
        }
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        let query = SnowflakeObjectQueries.routineDefinition(
            kind: routine.kind == .procedure ? "PROCEDURE" : "FUNCTION",
            schema: routine.schema ?? currentSchema,
            name: routine.name,
            signature: routine.identity ?? routine.argumentSignature
        )
        let result = try await execute(query: query)
        guard let ddl = result.rows.first?[safe: 0]?.asText, !ddl.isEmpty else {
            throw PluginObjectSourceError.insufficientPrivilege(routine.name)
        }
        return ddl
    }
}
