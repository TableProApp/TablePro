//
//  MSSQLPluginDriver+Schema.swift
//  MSSQLDriverPlugin
//

import Foundation
import os
import TableProLogRedaction
import TableProMSSQLCore
import TableProPluginKit

extension MSSQLPluginDriver {
    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let resolved = effectiveSchema(schema)
        return try await listTables(in: .schema(resolved), schemaFallback: resolved)
    }

    func fetchTablesInAllSchemas() async throws -> [PluginTableInfo]? {
        try await listTables(in: .allSchemas, schemaFallback: nil)
    }

    func fetchTables(inSchemas schemas: [String]) async throws -> [PluginTableInfo]? {
        guard !schemas.isEmpty else { return [] }
        return try await listTables(in: .schemas(schemas), schemaFallback: nil)
    }

    private func listTables(
        in scope: MSSQLTableListingScope,
        schemaFallback: String?
    ) async throws -> [PluginTableInfo] {
        let result = try await execute(query: MSSQLSchemaQueries.tables(in: scope))
        return result.rows.compactMap { row -> PluginTableInfo? in
            guard let table = MSSQLSchemaQueries.parseTableRow(row.map(\.asText)) else { return nil }
            return PluginTableInfo(
                name: table.name,
                type: table.isView ? "VIEW" : "TABLE",
                schema: table.schema ?? schemaFallback
            )
        }
    }

    func fetchTemporaryTables() async throws -> [PluginTableInfo] {
        let result = try await execute(query: MSSQLSchemaQueries.temporaryTables)
        return result.rows.compactMap { row in
            row[safe: 0]?.asText.map { PluginTableInfo(name: $0, type: "TABLE") }
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let sql = MSSQLSchemaQueries.namesTemporaryTable(table)
            ? MSSQLSchemaQueries.temporaryColumns(table: table)
            : MSSQLSchemaQueries.columns(schema: effectiveSchema(schema), table: table)
        let result = try await execute(query: sql)
        return result.rows.compactMap { row in
            MSSQLSchemaQueries.parseColumnRow(row.map(\.asText)).map(\.pluginColumnInfo)
        }
    }

    func fetchViewRowEditing(view: String, schema: String?) async throws -> PluginViewRowEditing? {
        let schema = effectiveSchema(schema)
        let factRows = try await viewCatalogRows(MSSQLViewSources.viewFactsQuery(schema: schema, view: view))
        guard let facts = MSSQLViewSources.ViewFacts(rows: factRows) else { return nil }
        if let refusal = facts.refusal { return .readOnly(PluginViewReadOnlyReason(refusal)) }

        let browse = MSSQLViewSources.BrowseFacts(
            rows: try await viewCatalogRows(MSSQLViewSources.browseQuery(schema: schema, view: view))
        )
        let baseTable: MSSQLViewSources.BaseTable
        switch browse.source {
        case .refused(let refusal):
            return .readOnly(PluginViewReadOnlyReason(refusal))
        case .table(let table):
            baseTable = table
        }

        let probeRows = try await viewCatalogRows(MSSQLViewSources.probesQuery(
            schema: schema,
            view: view,
            writableColumns: browse.writableColumns
        ))
        let operations = MSSQLViewSources.allowedOperations(
            writableColumns: browse.writableColumns,
            probeRows: probeRows
        )
        let base = MSSQLViewSources.BaseFacts(
            rows: try await viewCatalogRows(MSSQLViewSources.baseColumnsQuery(baseTable))
        )

        return PluginViewRowEditing.resolve(
            operations: PluginViewWriteOperations(operations),
            baseTable: PluginViewBaseTable(
                database: baseTable.database,
                schema: baseTable.schema,
                name: baseTable.name
            ),
            columns: browse.columns.map {
                PluginViewColumn(name: $0.name, baseColumn: $0.baseColumn, acceptsWrites: $0.acceptsWrites)
            },
            baseKeyColumns: base?.keyColumns,
            baseColumns: base?.columns.map {
                PluginViewBaseColumn(
                    name: $0.name,
                    isNullable: $0.isNullable,
                    defaultValue: $0.defaultValue,
                    assignsValue: $0.assignsValue,
                    acceptsWrites: $0.acceptsWrites
                )
            }
        )
    }

    private func viewCatalogRows(_ query: String) async throws -> [[String?]] {
        try await execute(query: query).rows.map { $0.map(\.asText) }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        /// Bracket-escaped for the identifier and literal-escaped for the string it sits in:
        /// SQL Server allows both `]` and `'` in an identifier.
        let objectLiteral = MSSQLStringLiteral.quoted(
            MSSQLSchemaQueries.bracketed(schema: effectiveSchema(schema), table: table))
        let sql = MSSQLSchemaQueries.namesTemporaryTable(table)
            ? MSSQLSchemaQueries.temporaryIndexes(table: table)
            : """
            SELECT i.name, i.is_unique, i.is_primary_key, c.name AS column_name, i.type_desc
            FROM sys.indexes i
            JOIN sys.index_columns ic
                ON i.object_id = ic.object_id AND i.index_id = ic.index_id
            JOIN sys.columns c
                ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE i.object_id = OBJECT_ID(\(objectLiteral))
              AND i.name IS NOT NULL
            ORDER BY i.index_id, ic.key_ordinal
            """
        let result = try await execute(query: sql)
        var indexMap: [String: (unique: Bool, primary: Bool, columns: [String], type: String)] = [:]
        for row in result.rows {
            guard let idxName = row[safe: 0]?.asText,
                  let colName = row[safe: 3]?.asText else { continue }
            let isUnique = (row[safe: 1]?.asText) == "1"
            let isPrimary = (row[safe: 2]?.asText) == "1"
            if indexMap[idxName] == nil {
                indexMap[idxName] = (
                    unique: isUnique,
                    primary: isPrimary,
                    columns: [],
                    type: row[safe: 4]?.asText ?? "NONCLUSTERED")
            }
            indexMap[idxName]?.columns.append(colName)
        }
        return indexMap.map { name, info in
            PluginIndexInfo(
                name: name,
                columns: info.columns,
                isUnique: info.unique,
                isPrimary: info.primary,
                type: info.type
            )
        }.sorted { $0.name < $1.name }
    }

    /// A table can hold exactly one clustered index, and the primary key usually is it, so a
    /// synthesised statement has to say which kind each index is: scripting them all as
    /// `CLUSTERED` makes the server reject the second with "Cannot create more than one clustered
    /// index".
    ///
    /// A key column and an `INCLUDE` column are told apart by `is_included_column`, and a filtered
    /// index's predicate comes from the catalog already parenthesised.
    ///
    /// Only the primary key's index is excluded. `fetchTableDDL` declares the primary key inline
    /// and the foreign keys, but never a `UNIQUE` constraint, so that constraint's index has to
    /// come through here or `CREATE TABLE t (a INT UNIQUE)` round-trips with no uniqueness at all.
    func fetchIndexDDL(table: String, schema: String?) async throws -> [String] {
        /// The bracketed name is spliced into a string literal, so a name carrying a quote needs
        /// the literal escape as well as the bracket one. SQL Server allows both characters in an
        /// identifier.
        let objectLiteral = MSSQLStringLiteral.quoted(
            MSSQLSchemaQueries.bracketed(schema: effectiveSchema(schema), table: table))
        let sql = """
            SELECT i.name, i.type_desc, i.is_unique, i.filter_definition,
                   c.name AS column_name, ic.is_included_column, ic.is_descending_key
            FROM sys.indexes i
            JOIN sys.index_columns ic
                ON i.object_id = ic.object_id AND i.index_id = ic.index_id
            JOIN sys.columns c
                ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE i.object_id = OBJECT_ID(\(objectLiteral))
              AND i.name IS NOT NULL
              AND i.is_primary_key = 0
              AND i.type IN (1, 2)
            ORDER BY i.index_id, ic.is_included_column, ic.key_ordinal
            """
        let result = try await execute(query: sql)
        return MSSQLSchemaQueries.indexStatements(
            rows: result.rows.map { row in row.map { $0.asText } },
            schema: effectiveSchema(schema),
            table: table)
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let sql = MSSQLSchemaQueries.foreignKeys(schema: effectiveSchema(schema), table: table)
        let result = try await execute(query: sql)
        return result.rows.compactMap { row in
            MSSQLSchemaQueries.parseForeignKeyRow(row.map { $0.asText }).map(Self.foreignKey)
        }
    }

    private static func foreignKey(_ row: MSSQLForeignKeyRow) -> PluginForeignKeyInfo {
        PluginForeignKeyInfo(
            name: row.constraintName,
            column: row.columnName,
            referencedTable: row.referencedTable,
            referencedColumn: row.referencedColumn,
            referencedSchema: row.referencedSchema,
            onDelete: row.onDelete,
            onUpdate: row.onUpdate
        )
    }

    func fetchTriggers(table: String, schema: String?) async throws -> [PluginTriggerInfo] {
        try await triggerList(schema: effectiveSchema(schema), table: table)
    }
    var triggerEditUsesReplace: Bool { true }

    var supportsTransactionalDDL: Bool { true }

    func createTriggerTemplate(table: String, schema: String?) -> String? {
        let resolved = effectiveSchema(schema)
        return """
        CREATE OR ALTER TRIGGER \(quoteIdentifier("trigger_name"))
        ON \(quoteIdentifier(resolved)).\(quoteIdentifier(table))
        AFTER INSERT
        AS
        BEGIN
            SET NOCOUNT ON;
            -- INSERT INTO audit (...) SELECT ... FROM inserted;
        END
        """
    }

    func fetchTriggerDefinition(name: String, table: String, schema: String?) async throws -> String? {
        let esc = MSSQLSchemaQueries.escapeBracket(effectiveSchema(schema))
        let bracketedName = name.replacingOccurrences(of: "]", with: "]]", options: .literal)
        let objectLiteral = MSSQLStringLiteral.quoted("[\(esc)].[\(bracketedName)]")
        let sql = "SELECT OBJECT_DEFINITION(OBJECT_ID(\(objectLiteral)))"
        let result = try await execute(query: sql)
        guard let definition = result.rows.first?[safe: 0]?.asText, !definition.isEmpty else { return nil }
        guard let range = definition.range(of: "CREATE TRIGGER", options: .caseInsensitive) else {
            return definition
        }
        return definition.replacingCharacters(in: range, with: "CREATE OR ALTER TRIGGER")
    }

    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? {
        let resolved = effectiveSchema(schema)
        return "DROP TRIGGER \(quoteIdentifier(resolved)).\(quoteIdentifier(name))"
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let result = try await execute(query: MSSQLSchemaQueries.allColumns(schema: effectiveSchema(schema)))
        var columnsByTable: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            let cells = row.map(\.asText)
            guard let tableName = cells[safe: MSSQLSchemaQueries.allColumnsTableNameIndex] ?? nil,
                  let column = MSSQLSchemaQueries.parseColumnRow(cells) else { continue }
            columnsByTable[tableName, default: []].append(column.pluginColumnInfo)
        }
        return columnsByTable
    }

    var providesBulkForeignKeyFetch: Bool { true }

    var tableDDLIncludesForeignKeys: Bool { true }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        let result = try await execute(query: MSSQLSchemaQueries.foreignKeys(schema: effectiveSchema(schema), table: nil))
        var fksByTable: [String: [PluginForeignKeyInfo]] = [:]
        for row in result.rows {
            guard let parsed = MSSQLSchemaQueries.parseForeignKeyRow(row.map { $0.asText }),
                  let table = parsed.table else { continue }
            fksByTable[table, default: []].append(Self.foreignKey(parsed))
        }
        return fksByTable
    }

    private static let metadataLogger = Logger(subsystem: "com.TablePro", category: "MSSQLPluginDriver")

    /// Each database answers for itself, so a login that can open a database gets its real size and count. A
    /// database that cannot be opened keeps its row, with the server-wide file size when that view is readable.
    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let names = try await fetchDatabases()
        var metadata: [PluginDatabaseMetadata] = []
        var unreadable: Set<String> = []
        for name in names {
            do {
                metadata.append(try await fetchDatabaseMetadata(name))
            } catch {
                Self.metadataLogger.debug(
                    "No metadata for database \(name, privacy: .private(mask: .hash)): \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
                )
                unreadable.insert(name)
                metadata.append(PluginDatabaseMetadata(name: name))
            }
        }
        guard !unreadable.isEmpty else { return metadata }
        let sizes = await serverWideDatabaseSizes()
        return metadata.map { entry in
            guard unreadable.contains(entry.name), let size = sizes[entry.name] else { return entry }
            return PluginDatabaseMetadata(name: entry.name, sizeBytes: size)
        }
    }

    private func serverWideDatabaseSizes() async -> [String: Int64] {
        do {
            let result = try await execute(query: MSSQLSchemaQueries.allDatabaseSizes)
            var sizes: [String: Int64] = [:]
            for row in result.rows {
                guard let name = row[safe: 0]?.asText,
                      let size = (row[safe: 1]?.asText).flatMap({ Int64($0) }) else { continue }
                sizes[name] = size
            }
            return sizes
        } catch {
            Self.metadataLogger.debug("Server-wide database sizes unavailable: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            return [:]
        }
    }

    /// A view answers with its own definition. Its columns are listed like a table's, and a column
    /// over an identity column reports `IsIdentity`, so a table rebuilt from them read
    /// `CREATE TABLE ... IDENTITY(1,1)` for a view that declares nothing of the kind.
    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let resolvedSchema = effectiveSchema(schema)
        let module = try await storedModule(schema: resolvedSchema, name: table)
        if MSSQLObjectQueries.isView(objectType: module?[safe: 2].flatMap { $0 } ?? "") {
            return try MSSQLObjectQueries.viewSource(row: module, schema: resolvedSchema, name: table)
        }

        let qualified = MSSQLSchemaQueries.bracketed(schema: resolvedSchema, table: table)
        let cols = try await fetchColumns(table: table, schema: schema)
        let indexes = try await fetchIndexes(table: table, schema: schema)
        let fks = try await fetchForeignKeys(table: table, schema: schema)

        var ddl = "CREATE TABLE \(qualified) (\n"
        let colDefs = cols.map { col -> String in
            var def = "    [\(col.name)] \(col.dataType.uppercased())"
            if col.extra == "IDENTITY" { def += " IDENTITY(1,1)" }
            def += col.isNullable ? " NULL" : " NOT NULL"
            if let d = col.defaultValue { def += " DEFAULT \(d)" }
            return def
        }

        let pkCols = indexes.filter(\.isPrimary).flatMap(\.columns)
        var parts = colDefs
        if !pkCols.isEmpty {
            let pkName = "PK_\(table)"
            let pkDef = "    CONSTRAINT [\(pkName)] PRIMARY KEY (\(pkCols.map { "[\($0)]" }.joined(separator: ", ")))"
            parts.append(pkDef)
        }

        for fk in fks {
            let fkDef = "    CONSTRAINT [\(fk.name)] FOREIGN KEY ([\(fk.column)]) REFERENCES [\(fk.referencedTable)] ([\(fk.referencedColumn)])"
            parts.append(fkDef)
        }

        ddl += parts.joined(separator: ",\n")
        ddl += "\n);"
        return ddl
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let resolvedSchema = effectiveSchema(schema)
        let module = try await storedModule(schema: resolvedSchema, name: view)
        return try MSSQLObjectQueries.viewSource(row: module, schema: resolvedSchema, name: view)
    }

    private func storedModule(schema: String, name: String) async throws -> [String?]? {
        let result = try await execute(query: MSSQLObjectQueries.moduleDefinition(schema: schema, name: name))
        return result.rows.first.map { $0.map(\.asText) }
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let tableLiteral = MSSQLStringLiteral.quoted(table)
        let schemaLiteral = effectiveSchemaQuoted(schema)
        let sql = """
            SELECT
                SUM(p.rows) AS row_count,
                8 * SUM(a.used_pages) AS size_kb,
                ep.value AS comment
            FROM sys.tables t
            JOIN sys.schemas s ON t.schema_id = s.schema_id
            JOIN sys.partitions p
                ON t.object_id = p.object_id AND p.index_id IN (0, 1)
            JOIN sys.allocation_units a ON p.partition_id = a.container_id
            LEFT JOIN sys.extended_properties ep
                ON ep.major_id = t.object_id AND ep.minor_id = 0 AND ep.name = 'MS_Description'
            WHERE t.name = \(tableLiteral) AND s.name = \(schemaLiteral)
            GROUP BY ep.value
            """
        let result = try await execute(query: sql)
        if let row = result.rows.first {
            let rowCount = (row[safe: 0]?.asText).flatMap { Int64($0) }
            let sizeKb = (row[safe: 1]?.asText).flatMap { Int64($0) } ?? 0
            let comment = row[safe: 2]?.asText
            return PluginTableMetadata(
                tableName: table,
                dataSize: sizeKb * 1_024,
                totalSize: sizeKb * 1_024,
                rowCount: rowCount,
                comment: comment
            )
        }
        let viewComment = await viewDescription(view: table, schema: schema)
        return PluginTableMetadata(tableName: table, comment: viewComment)
    }

    private func viewDescription(view: String, schema: String?) async -> String? {
        let sql = MSSQLTableDefinitionSQL.descriptionQuery(
            schema: effectiveSchema(schema), objectKind: "VIEW", object: view
        )
        guard let result = try? await execute(query: sql) else { return nil }
        return result.rows.first?.first?.asText?.nilIfEmpty
    }

    func fetchDatabases() async throws -> [String] {
        let sql = "SELECT name FROM sys.databases ORDER BY name"
        let result = try await execute(query: sql)
        return result.rows.compactMap { $0.first?.asText }
    }

    func fetchSchemas() async throws -> [String] {
        let result = try await execute(query: MSSQLSchemaQueries.schemas)
        return result.rows.compactMap { $0.first?.asText }
    }

    func switchSchema(to schema: String) async throws {
        currentSchemaName = schema
    }

    func switchDatabase(to database: String) async throws {
        guard let conn = freeTDSConn else {
            throw MSSQLPluginError.notConnected
        }
        try await conn.switchDatabase(database)
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let result = try await execute(query: MSSQLSchemaQueries.databaseMetadata(database: database))
        guard let row = result.rows.first else { return PluginDatabaseMetadata(name: database) }
        return PluginDatabaseMetadata(
            name: database,
            tableCount: (row[safe: 1]?.asText).flatMap { Int($0) },
            sizeBytes: (row[safe: 0]?.asText).flatMap { Int64($0) }
        )
    }

    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? {
        PluginCreateDatabaseFormSpec(fields: [], footnote: nil)
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        let quotedName = "[\(request.name.replacingOccurrences(of: "]", with: "]]", options: .literal))]"
        _ = try await execute(query: "CREATE DATABASE \(quotedName)")
    }

    func dropDatabase(name: String) async throws {
        let quotedName = "[\(name.replacingOccurrences(of: "]", with: "]]", options: .literal))]"
        _ = try await execute(query: "DROP DATABASE \(quotedName)")
    }

    func dropSchema(name: String) async throws {
        let quotedName = "[\(name.replacingOccurrences(of: "]", with: "]]", options: .literal))]"
        _ = try await execute(query: "DROP SCHEMA \(quotedName)")
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        """
        SELECT
            s.name as schema_name,
            t.name as name,
            CASE WHEN v.object_id IS NOT NULL THEN 'VIEW' ELSE 'TABLE' END as kind,
            p.rows as estimated_rows,
            CAST(ROUND(ISNULL(SUM(a.total_pages), 0) * 8 / 1024.0, 2) AS VARCHAR) + ' MB' as total_size
        FROM sys.tables t
        INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
        INNER JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id IN (0, 1)
        INNER JOIN sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
        INNER JOIN sys.allocation_units a ON p.partition_id = a.container_id
        LEFT JOIN sys.views v ON t.object_id = v.object_id
        GROUP BY s.name, t.name, p.rows, v.object_id
        ORDER BY t.name
        """
    }
}

extension MSSQLColumnRow {
    var pluginColumnInfo: PluginColumnInfo {
        PluginColumnInfo(
            name: name,
            dataType: displayType,
            isNullable: isNullable,
            isPrimaryKey: isPrimaryKey,
            defaultValue: defaultValue,
            extra: isIdentity ? "IDENTITY" : nil,
            identityKind: isIdentity ? .always : nil,
            isGenerated: isGenerated
        )
    }
}

private extension PluginViewReadOnlyReason {
    init(_ refusal: MSSQLViewSources.Refusal) {
        switch refusal {
        case .notUpdatable: self = .notUpdatable
        case .writesRunTriggers: self = .writesRunTriggers
        case .readsSeveralTables: self = .readsSeveralTables
        case .baseTableHidden: self = .baseTableHidden
        }
    }
}

private extension PluginViewWriteOperations {
    init(_ operations: Set<MSSQLViewSources.Operation>) {
        self = []
        for operation in operations {
            switch operation {
            case .update: insert(.update)
            case .insert: insert(.insert)
            case .delete: insert(.delete)
            }
        }
    }
}
