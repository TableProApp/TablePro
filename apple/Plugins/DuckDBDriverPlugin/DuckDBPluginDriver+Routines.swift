//
//  DuckDBPluginDriver+Routines.swift
//  DuckDBDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

// DuckDB has macros where other engines have functions, and no procedures or triggers.
public enum DuckDBObjectQueries {
    // Macros only, since duckdb_functions() also lists every built-in. On the catalog, since it spans every attached one
    // and temp, whose overloads would merge into one statement. One row per parameter, read as a list element: the
    // list's text form quotes an element only when it holds certain characters. WITH ORDINALITY, since
    // generate_subscripts needs the core_functions extension the bundled library does not link. Overloads sort by
    // their parameters, so a rebuilt statement lists them in the same order every time.
    public static func macroList(catalog: String, schema: String?) -> String {
        let schemaPredicate = schema.map { " AND schema_name = \(DuckDBSchemaQueries.quoteLiteral($0))" } ?? ""
        return """
            SELECT f.macro_index, f.schema_name, f.function_name, f.macro_definition, f.function_type, p.parameter,
                f.parameter_types[p.position] AS parameter_type
            FROM (
                SELECT row_number() OVER (
                        ORDER BY schema_name, function_name, function_type, parameters, parameter_types
                    ) AS macro_index,
                    schema_name, function_name, macro_definition, function_type, parameters, parameter_types
                FROM duckdb_functions()
                WHERE database_name = \(DuckDBSchemaQueries.quoteLiteral(catalog))\(schemaPredicate)
                    AND function_type IN ('macro', 'table_macro') AND NOT internal
            ) AS f
            LEFT JOIN LATERAL unnest(f.parameters) WITH ORDINALITY AS p(parameter, position) ON true
            ORDER BY f.macro_index, p.position
            """
    }
}

struct DuckDBMacro {
    struct Parameter {
        let name: String
        let type: String?
    }

    let schema: String?
    let name: String
    let kind: String?
    let body: String?
    var parameters: [Parameter] = []

    // The identity Copy Objects and the export match on, so its format stays the one the listing always showed.
    var signature: String {
        "(\(parameters.map(\.name).joined(separator: ", ")))"
    }

    var isTableMacro: Bool {
        kind == "table_macro"
    }

    var routine: PluginRoutineInfo {
        var attributes: [PluginObjectAttribute] = []
        if let kind, !kind.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Kind", value: kind))
        }
        return PluginRoutineInfo(
            name: name,
            kind: .function,
            schema: schema,
            returnType: nil,
            language: "SQL",
            argumentSignature: signature,
            identity: nil,
            definition: body,
            attributes: attributes
        )
    }

    // Nil when the body does not read as one expression, or one query for a table macro, or a parameter type as one
    // type. DuckDB needs a table macro's query in parentheses once another overload follows it.
    var overloadDefinition: String? {
        guard let body else { return nil }
        let databaseTypeId = DuckDBPlugin.databaseTypeId
        let isSingle = isTableMacro
            ? SQLExpressionFragment.isSingleQuery(body, databaseTypeId: databaseTypeId)
            : SQLExpressionFragment.isSingleExpression(body, databaseTypeId: databaseTypeId)
        guard isSingle else { return nil }
        var parameterList: [String] = []
        for parameter in parameters {
            let quotedName = DuckDBSchemaQueries.quoteIdentifier(parameter.name)
            guard let type = parameter.type else {
                parameterList.append(quotedName)
                continue
            }
            guard SQLExpressionFragment.isSingleType(type, databaseTypeId: databaseTypeId) else { return nil }
            parameterList.append("\(quotedName) \(type)")
        }
        let parameterText = parameterList.joined(separator: ", ")
        return isTableMacro ? "(\(parameterText)) AS TABLE (\(body))" : "(\(parameterText)) AS \(body)"
    }

    // DuckDB keeps every overload of a name as one macro, so one statement creates them all; one per overload would
    // leave only the last. The catalog keeps no parameter defaults, so the statement has none.
    static func createStatement(overloads: [DuckDBMacro]) -> String? {
        guard let first = overloads.first else { return nil }
        var definitions: [String] = []
        for overload in overloads {
            guard let definition = overload.overloadDefinition else { return nil }
            definitions.append(definition)
        }
        let target = [first.schema, first.name].compactMap { $0 }.filter { !$0.isEmpty }
            .map(DuckDBSchemaQueries.quoteIdentifier)
            .joined(separator: ".")
        return "CREATE OR REPLACE MACRO \(target)\(definitions.joined(separator: ", "));"
    }
}

extension DuckDBPluginDriver {
    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        try await fetchMacros(schema: schema).map(\.routine)
    }

    // DuckDB keeps the parsed macro, not the CREATE MACRO text, so the statement is rebuilt from the catalog.
    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        let signature = routine.argumentSignature ?? "()"
        // A scalar and a table macro may share a name and parameters.
        let kind = routine.attributes.first { $0.label == "Kind" }?.value
        let macros = try await fetchMacros(schema: routine.schema)
        guard let macro = macros.first(where: {
            $0.name == routine.name && $0.signature == signature && (kind == nil || $0.kind == kind)
        }) else {
            throw PluginObjectSourceError.notFound(routine.name)
        }
        let overloads = macros.filter { $0.schema == macro.schema && $0.name == macro.name && $0.kind == macro.kind }
        guard let statement = DuckDBMacro.createStatement(overloads: overloads) else {
            throw DuckDBPluginError.queryFailed(String(
                format: String(localized: "TablePro cannot rebuild the definition of %@ from what the server reported."),
                routine.name
            ))
        }
        return statement
    }

    private func fetchMacros(schema: String?) async throws -> [DuckDBMacro] {
        let result = try await execute(query: DuckDBObjectQueries.macroList(catalog: try requireCatalog(), schema: schema))
        var macros: [DuckDBMacro] = []
        var currentIndex: String?
        for row in result.rows {
            guard let index = row[safe: 0]?.asText, let name = row[safe: 2]?.asText, !name.isEmpty else { continue }
            if index != currentIndex {
                currentIndex = index
                macros.append(DuckDBMacro(
                    schema: row[safe: 1]?.asText,
                    name: name,
                    kind: row[safe: 4]?.asText,
                    body: row[safe: 3]?.asText
                ))
            }
            if let parameter = row[safe: 5]?.asText {
                macros[macros.count - 1].parameters.append(
                    DuckDBMacro.Parameter(name: parameter, type: row[safe: 6]?.asText)
                )
            }
        }
        return macros
    }
}
