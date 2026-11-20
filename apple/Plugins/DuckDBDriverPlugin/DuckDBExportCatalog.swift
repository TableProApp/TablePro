//
//  DuckDBExportCatalog.swift
//  DuckDBDriverPlugin
//

import Foundation
import TableProDuckDBCore
import TableProPluginKit
import TableProSQLGrammar

// The catalog reads and the statements rebuilt from them, over whichever session the app hands in. Every read names
// the catalog because `duckdb_*()` spans every attached database.
nonisolated enum DuckDBExportCatalog {
    // Binds `$1..$3`; the macro list binds nothing.
    typealias Run = @Sendable (String, [PluginCellValue]) async throws -> PluginQueryResult

    static let tableDDLIncludesForeignKeys = true

    static func tables(catalog: String, schema: String, run: Run) async throws -> [PluginTableInfo] {
        let result = try await run(DuckDBSchemaQueries.listTables(in: .schema), [.text(catalog), .text(schema)])
        return tableInfos(from: result)
    }

    static func tableInfos(from result: PluginQueryResult) -> [PluginTableInfo] {
        result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText else { return nil }
            let typeString = (row[safe: 1]?.asText) ?? "BASE TABLE"
            let tableType = typeString.uppercased().contains("VIEW") ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: tableType, schema: row[safe: 2]?.asText)
        }
    }

    static func columns(catalog: String, schema: String, table: String, run: Run) async throws -> [PluginColumnInfo] {
        let result = try await run(DuckDBSchemaQueries.columnsForTable, [.text(catalog), .text(schema), .text(table)])
        let pkResult = try await run(
            DuckDBSchemaQueries.primaryKeyColumnsForTable,
            [.text(catalog), .text(schema), .text(table)]
        )
        // By bytes: a table can hold two columns whose names differ only in Unicode form.
        let pkColumns = Set(pkResult.rows.compactMap { $0[safe: 0]?.asText.map { Array($0.utf8) } })

        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText,
                  let dataType = row[safe: 1]?.asText else {
                return nil
            }
            return PluginColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: isNullableFlag(row[safe: 2]?.asText),
                isPrimaryKey: pkColumns.contains(Array(name.utf8)),
                defaultValue: row[safe: 3]?.asText,
                comment: row[safe: 5]?.asText?.nilIfEmpty,
                allowedValues: enumValues(dataType: dataType)
            )
        }
    }

    static func allColumns(
        catalog: String,
        schema: String,
        keepsSpellingsApart: Bool = false,
        run: Run
    ) async throws -> [String: [PluginColumnInfo]] {
        let result = try await run(DuckDBSchemaQueries.columnsForSchema, [.text(catalog), .text(schema)])
        let pkResult = try await run(DuckDBSchemaQueries.primaryKeyColumnsForSchema, [.text(catalog), .text(schema)])
        if keepsSpellingsApart {
            try PluginNameSpellings.requireDistinctSpellings(in: result.rows + pkResult.rows, nameAt: 0)
        }
        var pkMap: [String: Set<[UInt8]>] = [:]
        for row in pkResult.rows {
            if let tableName = row[safe: 0]?.asText, let colName = row[safe: 1]?.asText {
                pkMap[tableName, default: []].insert(Array(colName.utf8))
            }
        }

        var allColumns: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard let tableName = row[safe: 0]?.asText,
                  let columnName = row[safe: 1]?.asText,
                  let dataType = row[safe: 2]?.asText else {
                continue
            }
            let column = PluginColumnInfo(
                name: columnName,
                dataType: dataType,
                isNullable: isNullableFlag(row[safe: 3]?.asText),
                isPrimaryKey: pkMap[tableName]?.contains(Array(columnName.utf8)) ?? false,
                defaultValue: row[safe: 4]?.asText,
                comment: row[safe: 6]?.asText?.nilIfEmpty,
                allowedValues: enumValues(dataType: dataType)
            )
            allColumns[tableName, default: []].append(column)
        }
        return allColumns
    }

    // A failed read lists no keys rather than failing the caller.
    static func foreignKeys(
        catalog: String,
        schema: String,
        table: String,
        run: Run
    ) async throws -> [PluginForeignKeyInfo] {
        do {
            let result = try await run(
                DuckDBSchemaQueries.foreignKeysForTable,
                [.text(catalog), .text(schema), .text(table)]
            )
            return result.rows.compactMap { row in
                guard let name = row[safe: 0]?.asText,
                      let column = row[safe: 1]?.asText,
                      let refTable = row[safe: 2]?.asText,
                      let refColumn = row[safe: 3]?.asText else {
                    return nil
                }
                return PluginForeignKeyInfo(
                    name: name,
                    column: column,
                    referencedTable: refTable,
                    referencedColumn: refColumn,
                    onDelete: (row[safe: 4]?.asText) ?? "NO ACTION",
                    onUpdate: (row[safe: 5]?.asText) ?? "NO ACTION"
                )
            }
        } catch {
            return []
        }
    }

    // The recorded statement first, since only it keeps LIST, STRUCT and MAP types; then a view's, since
    // `duckdb_tables()` has no row for a view; then one rebuilt from the columns.
    static func tableDDL(catalog: String, schema: String, table: String, run: Run) async throws -> String {
        let nativeResult = try await run(DuckDBSchemaQueries.tableDDL, [.text(catalog), .text(schema), .text(table)])
        if let firstRow = nativeResult.rows.first, let sql = firstRow[0].asText {
            return sql.hasSuffix(";") ? sql : sql + ";"
        }

        let viewResult = try await run(DuckDBSchemaQueries.viewDefinition, [.text(catalog), .text(schema), .text(table)])
        if let definition = viewResult.rows.first?[safe: 0]?.asText?.nilIfEmpty {
            return DuckDBViewDefinition.makeReplaceable(definition)
        }

        let columns = try await Self.columns(catalog: catalog, schema: schema, table: table, run: run)
        let fks = try await Self.foreignKeys(catalog: catalog, schema: schema, table: table, run: run)
        let refusal = columns.lazy.compactMap {
            duckdbColumnTextRefusal(name: $0.name, dataType: $0.dataType, defaultValue: $0.defaultValue)
        }.first
        if let refusal { throw DuckDBCatalogError.unreadable(refusal) }

        let quote = DuckDBSchemaQueries.quoteIdentifier
        var ddl = "CREATE TABLE \(quote(schema)).\(quote(table)) (\n"
        var allDefs = columns.map { col in
            var def = "  \(quote(col.name)) \(col.dataType)"
            if !col.isNullable { def += " NOT NULL" }
            if let defaultVal = col.defaultValue { def += " DEFAULT \(defaultVal)" }
            return def
        }

        let pkColumns = columns.filter(\.isPrimaryKey)
        if !pkColumns.isEmpty {
            allDefs.append("  PRIMARY KEY (\(pkColumns.map { quote($0.name) }.joined(separator: ", ")))")
        }

        for fk in fks {
            guard let onDelete = duckdbReferentialAction(fk.onDelete), let onUpdate = duckdbReferentialAction(fk.onUpdate)
            else {
                throw DuckDBCatalogError.unreadable(String(
                    format: String(localized: "The action of foreign key %@ cannot be written as SQL."), fk.name
                ))
            }
            allDefs.append(
                "  FOREIGN KEY (\(quote(fk.column)))"
                    + " REFERENCES \(quote(fk.referencedTable))"
                    + "(\(quote(fk.referencedColumn)))"
                    + " ON DELETE \(onDelete) ON UPDATE \(onUpdate)"
            )
        }

        ddl += allDefs.joined(separator: ",\n")
        ddl += "\n);"
        return ddl
    }

    static func viewDefinition(catalog: String, schema: String, view: String, run: Run) async throws -> String {
        let result = try await run(DuckDBSchemaQueries.viewDefinition, [.text(catalog), .text(schema), .text(view)])
        guard let firstRow = result.rows.first,
              let definition = firstRow[0].asText?.nilIfEmpty else {
            throw DuckDBCatalogError.unreadable("Failed to fetch definition for view '\(view)'")
        }
        return DuckDBViewDefinition.makeReplaceable(definition)
    }

    // A constraint's backing index is not a row of `duckdb_indexes()`, so nothing is filtered out.
    static func indexDDL(catalog: String, schema: String, table: String, run: Run) async throws -> [String] {
        let result = try await run(DuckDBSchemaQueries.indexDDLForTable, [.text(catalog), .text(schema), .text(table)])
        return result.rows.compactMap { $0[safe: 0]?.asText }
            .map { $0.hasSuffix(";") ? $0 : $0 + ";" }
    }

    static func routines(catalog: String, schema: String?, run: Run) async throws -> [PluginRoutineInfo] {
        try await macros(catalog: catalog, schema: schema, run: run).map(\.routine)
    }

    // DuckDB keeps the parsed macro, not the CREATE MACRO text, so the statement is rebuilt from the catalog.
    static func routineDDL(_ routine: PluginRoutineInfo, catalog: String, run: Run) async throws -> String {
        let signature = routine.argumentSignature ?? "()"
        // A scalar and a table macro may share a name and parameters.
        let kind = routine.attributes.first { $0.label == "Kind" }?.value
        let macros = try await Self.macros(catalog: catalog, schema: routine.schema, run: run)
        guard let macro = macros.first(where: {
            $0.name == routine.name && $0.signature == signature && (kind == nil || $0.kind == kind)
        }) else {
            throw PluginObjectSourceError.notFound(routine.name)
        }
        let overloads = macros.filter { $0.schema == macro.schema && $0.name == macro.name && $0.kind == macro.kind }
        guard let statement = DuckDBMacro.createStatement(overloads: overloads) else {
            throw DuckDBCatalogError.unreadable(String(
                format: String(localized: "TablePro cannot rebuild the definition of %@ from what the server reported."),
                routine.name
            ))
        }
        return statement
    }

    static func macros(catalog: String, schema: String?, run: Run) async throws -> [DuckDBMacro] {
        let result = try await run(DuckDBObjectQueries.macroList(catalog: catalog, schema: schema), [])
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

    // `duckdb_columns()` types `is_nullable` as BOOLEAN, so the value arrives as `true`.
    private static func isNullableFlag(_ value: String?) -> Bool {
        value == "true"
    }

    // DuckDB spells an ENUM column's type with its members, so they need no second read.
    private static func enumValues(dataType: String) -> [String]? {
        EnumValueParser.parseMySQLEnumOrSet(from: dataType)
    }
}

nonisolated enum DuckDBCatalogError: PluginDriverError {
    case unreadable(String)

    var pluginErrorMessage: String {
        switch self {
        case .unreadable(let message): return message
        }
    }
}

nonisolated struct DuckDBMacro {
    struct Parameter {
        let name: String
        let type: String?
    }

    let schema: String?
    let name: String
    let kind: String?
    let body: String?
    var parameters: [Parameter] = []

    // The identity Copy Objects and the export match on.
    var signature: String {
        DuckDBObjectQueries.macroSignature(parameterNames: parameters.map(\.name), isTableMacro: isTableMacro)
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
        let databaseTypeId = duckdbDatabaseTypeId
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
        let target = DuckDBObjectQueries.qualifiedName(schema: first.schema, name: first.name)
        return "CREATE OR REPLACE MACRO \(target)\(definitions.joined(separator: ", "));"
    }
}
