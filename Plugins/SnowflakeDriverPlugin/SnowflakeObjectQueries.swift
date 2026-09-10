//
//  SnowflakeObjectQueries.swift
//  SnowflakeDriverPlugin
//
//  SQL builders for procedures and functions. Pure text, no driver state, so the escaping these
//  statements depend on can be tested directly.
//

import Foundation

/// Snowflake has procedures and functions and no triggers.
public enum SnowflakeObjectQueries {
    public static func routineList(schema: String) -> String {
        let schemaLiteral = SnowflakeSQL.escapeLiteral(schema)
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
        return "SELECT GET_DDL('\(SnowflakeSQL.escapeLiteral(kind))', '\(SnowflakeSQL.escapeLiteral(qualified + arguments))')"
    }
}
