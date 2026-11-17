import Foundation
import TableProSQLQuoting

// DuckDB has macros where other engines have functions, and no procedures or triggers.
public enum DuckDBObjectQueries {
    // Macros only, since duckdb_functions() also lists every built-in. On the catalog, since it spans every attached one
    // and temp, whose overloads would merge into one statement. One row per parameter, read as a list element: the
    // list's text form quotes an element only when it holds certain characters. WITH ORDINALITY, since
    // generate_subscripts needs the core_functions extension the bundled library does not link. Overloads sort by
    // their parameters, so a rebuilt statement lists them in the same order every time.
    public static func macroList(catalog: String, schema: String?) -> String {
        let schemaPredicate = schema.map { " AND schema_name = \(SQLQuoting.stringLiteral($0))" } ?? ""
        return """
            SELECT f.macro_index, f.schema_name, f.function_name, f.macro_definition, f.function_type, p.parameter,
                f.parameter_types[p.position] AS parameter_type
            FROM (
                SELECT row_number() OVER (
                        ORDER BY schema_name, function_name, function_type, parameters, parameter_types
                    ) AS macro_index,
                    schema_name, function_name, macro_definition, function_type, parameters, parameter_types
                FROM duckdb_functions()
                WHERE database_name = \(SQLQuoting.stringLiteral(catalog))\(schemaPredicate)
                    AND function_type IN ('macro', 'table_macro') AND NOT internal
            ) AS f
            LEFT JOIN LATERAL unnest(f.parameters) WITH ORDINALITY AS p(parameter, position) ON true
            ORDER BY f.macro_index, p.position
            """
    }

    // An empty or missing schema leaves the name to resolve in the session's own.
    public static func qualifiedName(schema: String?, name: String) -> String {
        [schema, name].compactMap { $0 }.filter { !$0.isEmpty }
            .map { SQLQuoting.identifier($0) }
            .joined(separator: ".")
    }

    // DuckDB has no `DROP ROUTINE`. Measured on 2.0.0 and 1.5.4: `DROP MACRO` drops a table macro too, unless a scalar
    // macro shares its name, which it drops instead; `DROP MACRO TABLE` drops only a table macro.
    public static func dropMacro(name: String, schema: String?, isTableMacro: Bool) -> String {
        let keyword = isTableMacro ? "DROP MACRO TABLE" : "DROP MACRO"
        return "\(keyword) IF EXISTS \(qualifiedName(schema: schema, name: name))"
    }

    static let tableMacroSuffix = " AS TABLE"

    // A scalar and a table macro may share a name and parameters, and only the signature reaches the drop, so a table
    // macro's names its kind the way CREATE MACRO spells it.
    public static func macroSignature(parameterNames: [String], isTableMacro: Bool) -> String {
        let parameters = "(\(parameterNames.joined(separator: ", ")))"
        return isTableMacro ? parameters + tableMacroSuffix : parameters
    }

    // A scalar macro's signature ends with its closing parenthesis.
    public static func namesTableMacro(_ signature: String?) -> Bool {
        signature?.hasSuffix(tableMacroSuffix) ?? false
    }
}
