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

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let sql = MSSQLSchemaQueries.columns(schema: effectiveSchema(schema), table: table)
        let result = try await execute(query: sql)
        return result.rows.compactMap { row in
            MSSQLSchemaQueries.parseColumnRow(row.map(\.asText)).map(\.pluginColumnInfo)
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        /// Bracket-escaped for the identifier and literal-escaped for the string it sits in:
        /// SQL Server allows both `]` and `'` in an identifier.
        let objectLiteral = MSSQLStringLiteral.quoted(
            MSSQLSchemaQueries.bracketed(schema: effectiveSchema(schema), table: table))
        let sql = """
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
        return result.rows.compactMap { row -> PluginForeignKeyInfo? in
            guard let parsed = MSSQLSchemaQueries.parseForeignKeyRow(row.map { $0.asText }) else { return nil }
            return PluginForeignKeyInfo(
                name: parsed.constraintName,
                column: parsed.columnName,
                referencedTable: parsed.referencedTable,
                referencedColumn: parsed.referencedColumn,
                referencedSchema: parsed.referencedSchema
            )
        }
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
        let bracketedName = name.replacingOccurrences(of: "]", with: "]]")
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
        let schemaLiteral = effectiveSchemaQuoted(schema)
        let sql = """
            SELECT
                tp.name AS table_name,
                fk.name AS constraint_name,
                cp.name AS column_name,
                tr.name AS ref_table,
                cr.name AS ref_column,
                sr.name AS ref_schema
            FROM sys.foreign_keys fk
            JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
            JOIN sys.tables tp ON fkc.parent_object_id = tp.object_id
            JOIN sys.schemas s ON tp.schema_id = s.schema_id
            JOIN sys.columns cp
                ON fkc.parent_object_id = cp.object_id AND fkc.parent_column_id = cp.column_id
            JOIN sys.tables tr ON fkc.referenced_object_id = tr.object_id
            JOIN sys.schemas sr ON tr.schema_id = sr.schema_id
            JOIN sys.columns cr
                ON fkc.referenced_object_id = cr.object_id AND fkc.referenced_column_id = cr.column_id
            WHERE s.name = \(schemaLiteral)
            ORDER BY tp.name, fk.name
            """
        let result = try await execute(query: sql)
        var fksByTable: [String: [PluginForeignKeyInfo]] = [:]
        for row in result.rows {
            guard let tableName = row[safe: 0]?.asText,
                  let constraintName = row[safe: 1]?.asText,
                  let columnName = row[safe: 2]?.asText,
                  let refTable = row[safe: 3]?.asText,
                  let refColumn = row[safe: 4]?.asText else { continue }
            let fk = PluginForeignKeyInfo(
                name: constraintName,
                column: columnName,
                referencedTable: refTable,
                referencedColumn: refColumn,
                referencedSchema: row[safe: 5]?.asText
            )
            fksByTable[tableName, default: []].append(fk)
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

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let qualified = MSSQLSchemaQueries.bracketed(schema: effectiveSchema(schema), table: table)
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
        let viewLiteral = MSSQLStringLiteral.quoted("\(effectiveSchema(schema)).\(view)")
        let sql = "SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID(\(viewLiteral))"
        let result = try await execute(query: sql)
        return result.rows.first?.first?.asText ?? ""
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
        return PluginTableMetadata(tableName: table)
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
        _currentSchema = schema
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
        let quotedName = "[\(request.name.replacingOccurrences(of: "]", with: "]]"))]"
        _ = try await execute(query: "CREATE DATABASE \(quotedName)")
    }

    func dropDatabase(name: String) async throws {
        let quotedName = "[\(name.replacingOccurrences(of: "]", with: "]]"))]"
        _ = try await execute(query: "DROP DATABASE \(quotedName)")
    }

    func dropSchema(name: String) async throws {
        let quotedName = "[\(name.replacingOccurrences(of: "]", with: "]]"))]"
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
