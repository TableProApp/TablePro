//
//  SQLiteCatalogReads.swift
//  SQLiteDriverPlugin
//

import Foundation
import TableProPluginKit

// The catalog reads the macOS plugin and the iOS driver run over their own connection, so both apps export one schema.
nonisolated enum SQLiteCatalogReads {
    typealias Run = @Sendable (String) async throws -> PluginQueryResult

    static let tableDDLIncludesForeignKeys = true

    static let foreignKeyDisableStatements = ["PRAGMA foreign_keys = OFF"]
    static let foreignKeyEnableStatements = ["PRAGMA foreign_keys = ON"]

    static func columns(table: String, schema: String?, run: Run) async throws -> [PluginColumnInfo] {
        let safeTable = SQLiteMasterQueries.escapeLiteral(table)
        // table_info omits generated columns, which every write path reading this list has to see.
        let query = "SELECT * FROM pragma_table_xinfo('\(safeTable)'\(SQLiteMasterQueries.pragmaSchemaArgument(schema)))"
        let result = try await run(query)
        let generationExpressions = SQLiteCheckConstraintParser.generationExpressions(
            inCreateStatement: try await createTableStatement(table: table, schema: schema, run: run) ?? ""
        )

        return result.rows.compactMap { row in
            guard row.count >= 7,
                  let name = row[1].asText,
                  let dataType = row[2].asText else {
                return nil
            }

            // hidden: 0 normal, 1 a virtual table's hidden column, 2 VIRTUAL generated, 3 STORED generated.
            let hidden = row[6].asText.flatMap { Int($0) } ?? 0
            guard hidden != 1 else { return nil }

            let isNullable = row[3].asText == "0"
            // pk: 0 not in the key, 1+ the position in a composite key.
            let pkText = row[5].asText
            let isPrimaryKey = pkText != nil && pkText != "0"
            let defaultValue = sqliteDefaultValueFromCatalog(row[4].asText)
            let generationKind: GenerationKind? = hidden == 2 ? .virtual : (hidden == 3 ? .stored : nil)

            return PluginColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                isGenerated: generationKind != nil,
                generationExpression: generationKind == nil ? nil : generationExpressions[name],
                generationKind: generationKind
            )
        }
    }

    static func createTableStatement(table: String, schema: String?, run: Run) async throws -> String? {
        let query = SQLiteTemporarySchema.definitionQuery(name: table, types: ["table"], schema: schema)
        let result = try await run(query)
        return result.rows.first?[safe: 1]?.asText
    }

    static func checkConstraints(table: String, schema: String?, run: Run) async throws -> [PluginCheckConstraintInfo] {
        guard let statement = try await createTableStatement(table: table, schema: schema, run: run) else { return [] }
        return SQLiteCheckConstraintParser.constraints(inCreateStatement: statement).map { parsed in
            PluginCheckConstraintInfo(name: parsed.name, expression: parsed.expression)
        }
    }

    // `m.sql` rides along so the generation expressions come from the CREATE statement without a read per table.
    static func allColumns(
        schema: String?,
        keepsSpellingsApart: Bool = false,
        run: Run
    ) async throws -> [String: [PluginColumnInfo]] {
        let query = """
            SELECT m.name AS tbl, p.cid, p.name, p.type, p."notnull", p.dflt_value, p.pk,
                   p.hidden, m.sql
            FROM \(SQLiteMasterQueries.catalogTable(schema: schema)) m,
                 pragma_table_xinfo(m.name\(SQLiteMasterQueries.pragmaSchemaArgument(schema))) p
            WHERE m.type = 'table' AND m.name NOT GLOB 'sqlite_*'
            ORDER BY m.name, p.cid
            """
        let result = try await run(query)
        if keepsSpellingsApart {
            try PluginNameSpellings.requireDistinctSpellings(in: result.rows, nameAt: 0)
        }

        var allColumns: [String: [PluginColumnInfo]] = [:]
        var expressionsByTable: [String: [String: String]] = [:]

        for row in result.rows {
            guard row.count >= 9,
                  let tableName = row[0].asText,
                  let columnName = row[2].asText,
                  let dataType = row[3].asText else {
                continue
            }

            // hidden: 0 normal, 1 a virtual table's hidden column, 2 VIRTUAL generated, 3 STORED generated.
            let hidden = row[7].asText.flatMap { Int($0) } ?? 0
            guard hidden != 1 else { continue }

            let isNullable = row[4].asText == "0"
            let defaultValue = sqliteDefaultValueFromCatalog(row[5].asText)
            // pk: 0 not in the key, 1+ the position in a composite key.
            let pkText = row[6].asText
            let isPrimaryKey = pkText != nil && pkText != "0"
            let generationKind: GenerationKind? = hidden == 2 ? .virtual : (hidden == 3 ? .stored : nil)

            if generationKind != nil, expressionsByTable[tableName] == nil {
                expressionsByTable[tableName] = SQLiteCheckConstraintParser.generationExpressions(
                    inCreateStatement: row[8].asText ?? ""
                )
            }

            let column = PluginColumnInfo(
                name: columnName,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue,
                isGenerated: generationKind != nil,
                generationExpression: generationKind == nil ? nil : expressionsByTable[tableName]?[columnName],
                generationKind: generationKind
            )

            allColumns[tableName, default: []].append(column)
        }

        return allColumns
    }

    static func allForeignKeys(
        schema: String?,
        keepsSpellingsApart: Bool = false,
        run: Run
    ) async throws -> [String: [PluginForeignKeyInfo]] {
        let result = try await run(
            SQLiteForeignKeyGrouping.schemaForeignKeysQuery(schema: schema, excludingTableGlob: nil)
        )
        if keepsSpellingsApart {
            try PluginNameSpellings.requireDistinctSpellings(in: result.rows, nameAt: 0)
        }
        return SQLiteForeignKeyGrouping.foreignKeysByTable(schema: schema, fromRows: result.rows)
    }

    // A view goes back as written: SQLite keeps a trailing comment in it, which an appended `;` would land inside.
    static func tableDDL(table: String, schema: String?, run: Run) async throws -> String {
        let query = SQLiteTemporarySchema.definitionQuery(name: table, types: ["table", "view"], schema: schema)
        let result = try await run(query)

        guard let firstRow = result.rows.first,
              let ddl = firstRow[safe: 1]?.asText else {
            throw SQLiteCatalogReadError.missingTableDefinition(table)
        }

        guard firstRow[safe: 0]?.asText != "view" else { return ddl }
        return ddl.hasSuffix(";") ? ddl : ddl + ";"
    }

    static func viewDefinition(view: String, schema: String?, run: Run) async throws -> String {
        let safeView = SQLiteMasterQueries.escapeLiteral(view)
        let query = """
            SELECT sql FROM \(SQLiteMasterQueries.catalogTable(schema: schema))
            WHERE type = 'view' AND name = '\(safeView)'
            """
        let result = try await run(query)

        guard let firstRow = result.rows.first,
              let ddl = firstRow[0].asText else {
            throw SQLiteCatalogReadError.missingViewDefinition(view)
        }

        return ddl
    }

    // A null `sql` is an index SQLite made for a UNIQUE or PRIMARY KEY, which comes back inside `CREATE TABLE`.
    static func indexDDL(table: String, schema: String?, run: Run) async throws -> [String] {
        let result = try await run(SQLiteTemporarySchema.indexDefinitionsQuery(table: table, schema: schema))
        return result.rows.compactMap { $0[safe: 0]?.asText }
    }

    static func triggers(table: String?, schema: String?, run: Run) async throws -> [PluginTriggerInfo] {
        let query = SQLiteTemporarySchema.triggerListQuery(table: table, schema: schema)
        let result = try await run(query)
        return result.rows.compactMap { row -> PluginTriggerInfo? in
            guard row.count >= 3, let name = row[0].asText, let sql = row[2].asText else { return nil }
            return SQLiteMasterQueries.trigger(name: name, table: row[1].asText, schema: schema, sql: sql)
        }
    }

    static func triggerDDL(_ trigger: PluginTriggerInfo, run: Run) async throws -> String {
        if let definition = trigger.definition, !definition.isEmpty { return definition }
        let listed = try await triggers(table: trigger.table, schema: trigger.schema, run: run)
        guard let definition = listed.first(where: { $0.name == trigger.name })?.definition,
              !definition.isEmpty
        else {
            throw PluginObjectSourceError.notFound(trigger.name)
        }
        return definition
    }

    static func dropTriggerStatement(name: String, schema: String?) -> String {
        "DROP TRIGGER IF EXISTS \(SQLiteMasterQueries.qualifiedTable(name, schema: schema, quote: sqliteQuoteIdentifier))"
    }
}

nonisolated enum SQLiteCatalogReadError: Error, PluginDriverError {
    case missingTableDefinition(String)
    case missingViewDefinition(String)

    var pluginErrorMessage: String {
        switch self {
        case .missingTableDefinition(let table): "Failed to fetch DDL for table '\(table)'"
        case .missingViewDefinition(let view): "Failed to fetch definition for view '\(view)'"
        }
    }
}
