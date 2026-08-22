//
//  SnowflakePluginDriver+Routines.swift
//  SnowflakeDriverPlugin
//

import Foundation
import TableProPluginKit

/// Snowflake has procedures and functions and no triggers.
public enum SnowflakeObjectQueries {
    public static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    public static func routineList(schema: String) -> String {
        let schemaLiteral = escapeLiteral(schema)
        return """
            SELECT PROCEDURE_NAME AS NAME, PROCEDURE_SCHEMA AS SCHEMA_NAME, ARGUMENT_SIGNATURE,
                   DATA_TYPE, PROCEDURE_LANGUAGE AS LANGUAGE, 'PROCEDURE' AS ROUTINE_KIND
            FROM INFORMATION_SCHEMA.PROCEDURES
            WHERE PROCEDURE_SCHEMA = '\(schemaLiteral)'
            UNION ALL
            SELECT FUNCTION_NAME AS NAME, FUNCTION_SCHEMA AS SCHEMA_NAME, ARGUMENT_SIGNATURE,
                   DATA_TYPE, FUNCTION_LANGUAGE AS LANGUAGE, 'FUNCTION' AS ROUTINE_KIND
            FROM INFORMATION_SCHEMA.FUNCTIONS
            WHERE FUNCTION_SCHEMA = '\(schemaLiteral)'
            ORDER BY ROUTINE_KIND, NAME
            """
    }

    /// ARGUMENT_SIGNATURE names its parameters, `(A NUMBER, B VARCHAR)`, and GET_DDL accepts types
    /// alone, `(NUMBER, VARCHAR)`. Passing the signature through unchanged is an error, not a
    /// missing routine, so the names are dropped here.
    public static func argumentTypes(fromSignature signature: String?) -> String {
        guard let signature else { return "()" }
        let trimmed = signature.trimmingCharacters(in: .whitespaces)
        let inner = trimmed.hasPrefix("(") && trimmed.hasSuffix(")")
            ? String(trimmed.dropFirst().dropLast())
            : trimmed
        guard !inner.trimmingCharacters(in: .whitespaces).isEmpty else { return "()" }
        let types = inner.split(separator: ",").map { part -> String in
            let tokens = part.split(whereSeparator: { $0.isWhitespace })
            guard tokens.count > 1 else { return tokens.joined() }
            return tokens.dropFirst().joined(separator: " ")
        }
        return "(\(types.joined(separator: ", ")))"
    }

    /// GET_DDL needs the argument types inside the name, so a routine cannot be addressed without
    /// the signature the listing captured.
    public static func routineDefinition(kind: String, schema: String?, name: String, signature: String?) -> String {
        let arguments = argumentTypes(fromSignature: signature)
        let qualified = [schema, name].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ".")
        return "SELECT GET_DDL('\(escapeLiteral(kind))', '\(escapeLiteral(qualified + arguments))')"
    }
}

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
