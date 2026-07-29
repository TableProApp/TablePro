//
//  MSSQLPluginDriver+Schema.swift
//  MSSQLDriverPlugin
//

import Foundation
import os
import TableProMSSQLCore
import TableProPluginKit

extension MSSQLPluginDriver {
    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let esc = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT t.TABLE_NAME, t.TABLE_TYPE
            FROM INFORMATION_SCHEMA.TABLES t
            WHERE t.TABLE_SCHEMA = '\(esc)'
              AND t.TABLE_TYPE IN ('BASE TABLE', 'VIEW')
            ORDER BY t.TABLE_NAME
            """
        let result = try await execute(query: sql)
        return result.rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let rawType = row[safe: 1]?.asText
            let tableType = (rawType == "VIEW") ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: tableType)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let esc = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT
                c.COLUMN_NAME,
                c.DATA_TYPE,
                c.CHARACTER_MAXIMUM_LENGTH,
                c.NUMERIC_PRECISION,
                c.NUMERIC_SCALE,
                c.IS_NULLABLE,
                c.COLUMN_DEFAULT,
                COLUMNPROPERTY(OBJECT_ID(c.TABLE_SCHEMA + '.' + c.TABLE_NAME), c.COLUMN_NAME, 'IsIdentity') AS IS_IDENTITY,
                CASE WHEN pk.COLUMN_NAME IS NOT NULL THEN 1 ELSE 0 END AS IS_PK
            FROM INFORMATION_SCHEMA.COLUMNS c
            LEFT JOIN (
                SELECT kcu.COLUMN_NAME
                FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
                JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
                    ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
                    AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
                WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
                    AND tc.TABLE_SCHEMA = '\(esc)'
                    AND tc.TABLE_NAME = '\(escapedTable)'
            ) pk ON c.COLUMN_NAME = pk.COLUMN_NAME
            WHERE c.TABLE_NAME = '\(escapedTable)'
              AND c.TABLE_SCHEMA = '\(esc)'
            ORDER BY c.ORDINAL_POSITION
            """
        let result = try await execute(query: sql)
        var identityColumns: Set<String> = []
        let columns: [PluginColumnInfo] = result.rows.compactMap { row -> PluginColumnInfo? in
            guard let name = row[safe: 0]?.asText else { return nil }
            let dataType = row[safe: 1]?.asText
            let charLen = row[safe: 2]?.asText
            let numPrecision = row[safe: 3]?.asText
            let numScale = row[safe: 4]?.asText
            let isNullable = (row[safe: 5]?.asText) == "YES"
            let defaultValue = row[safe: 6]?.asText
            let isIdentity = (row[safe: 7]?.asText) == "1"
            let isPk = (row[safe: 8]?.asText) == "1"

            if isIdentity {
                identityColumns.insert(name)
            }

            let baseType = (dataType ?? "nvarchar").lowercased()
            let fixedSizeTypes: Set<String> = [
                "int", "bigint", "smallint", "tinyint", "bit",
                "money", "smallmoney", "float", "real",
                "datetime", "datetime2", "smalldatetime", "date", "time",
                "uniqueidentifier", "text", "ntext", "image", "xml",
                "timestamp", "rowversion"
            ]
            var fullType = baseType
            if fixedSizeTypes.contains(baseType) {
                // No suffix
            } else if let charLen, let len = Int(charLen), len > 0 {
                fullType += "(\(len))"
            } else if charLen == "-1" {
                fullType += "(max)"
            } else if let prec = numPrecision, let scale = numScale,
                      let p = Int(prec), let s = Int(scale) {
                fullType += "(\(p),\(s))"
            }

            return PluginColumnInfo(
                name: name,
                dataType: fullType,
                isNullable: isNullable,
                isPrimaryKey: isPk,
                defaultValue: defaultValue,
                extra: isIdentity ? "IDENTITY" : nil
            )
        }
        identityCacheLock.lock()
        identityColumnsByTable[table] = identityColumns
        identityCacheLock.unlock()
        return columns
    }

    /// Snapshot of IDENTITY columns observed by the most recent `fetchColumns` for the table.
    /// Returns an empty set when `fetchColumns` hasn't run for this table yet, so callers
    /// fall through to including every typed value (matching pre-cache behavior).
    internal func cachedIdentityColumns(for table: String) -> Set<String> {
        identityCacheLock.lock()
        defer { identityCacheLock.unlock() }
        return identityColumnsByTable[table] ?? []
    }

    /// Test seam: pre-populate the cache so generateMssqlInsert can be exercised
    /// without going through a live `fetchColumns` round-trip.
    internal func setIdentityColumnsForTesting(_ columns: Set<String>, table: String) {
        identityCacheLock.lock()
        identityColumnsByTable[table] = columns
        identityCacheLock.unlock()
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let esc = (schema ?? _currentSchema).replacingOccurrences(of: "]", with: "]]")
        let bracketedTable = table.replacingOccurrences(of: "]", with: "]]")
        let bracketedFull = "[\(esc)].[\(bracketedTable)]"
        let sql = """
            SELECT i.name, i.is_unique, i.is_primary_key, c.name AS column_name
            FROM sys.indexes i
            JOIN sys.index_columns ic
                ON i.object_id = ic.object_id AND i.index_id = ic.index_id
            JOIN sys.columns c
                ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE i.object_id = OBJECT_ID('\(bracketedFull)')
              AND i.name IS NOT NULL
            ORDER BY i.index_id, ic.key_ordinal
            """
        let result = try await execute(query: sql)
        var indexMap: [String: (unique: Bool, primary: Bool, columns: [String])] = [:]
        for row in result.rows {
            guard let idxName = row[safe: 0]?.asText,
                  let colName = row[safe: 3]?.asText else { continue }
            let isUnique = (row[safe: 1]?.asText) == "1"
            let isPrimary = (row[safe: 2]?.asText) == "1"
            if indexMap[idxName] == nil {
                indexMap[idxName] = (unique: isUnique, primary: isPrimary, columns: [])
            }
            indexMap[idxName]?.columns.append(colName)
        }
        return indexMap.map { name, info in
            PluginIndexInfo(
                name: name,
                columns: info.columns,
                isUnique: info.unique,
                isPrimary: info.primary,
                type: "CLUSTERED"
            )
        }.sorted { $0.name < $1.name }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let sql = MSSQLSchemaQueries.foreignKeys(schema: schema ?? _currentSchema, table: table)
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
        let esc = (schema ?? _currentSchema).replacingOccurrences(of: "]", with: "]]")
        let bracketedTable = table.replacingOccurrences(of: "]", with: "]]")
        let bracketedFull = "[\(esc)].[\(bracketedTable)]"
        let sql = """
            SELECT t.name, t.is_disabled, t.is_instead_of_trigger,
                   OBJECT_DEFINITION(t.object_id) AS definition,
                   te.type_desc AS event
            FROM sys.triggers t
            JOIN sys.trigger_events te ON t.object_id = te.object_id
            WHERE t.parent_id = OBJECT_ID('\(bracketedFull)')
            ORDER BY t.name, te.type_desc
            """
        let result = try await execute(query: sql)

        var order: [String] = []
        var byName: [String: (timing: String, definition: String, enabled: Bool, events: [String])] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText else { continue }
            let event = row[safe: 4]?.asText ?? ""
            if byName[name] == nil {
                order.append(name)
                let timing = (row[safe: 2]?.asText == "1") ? "INSTEAD OF" : "AFTER"
                let enabled = (row[safe: 1]?.asText != "1")
                byName[name] = (timing: timing, definition: row[safe: 3]?.asText ?? "", enabled: enabled, events: [])
            }
            if !event.isEmpty {
                byName[name]?.events.append(event)
            }
        }
        return order.compactMap { name in
            guard let info = byName[name] else { return nil }
            return PluginTriggerInfo(
                name: name,
                timing: info.timing,
                event: info.events.joined(separator: " OR "),
                statement: info.definition,
                enabled: info.enabled
            )
        }
    }

    var triggerEditUsesReplace: Bool { true }

    var supportsTransactionalDDL: Bool { true }

    func createTriggerTemplate(table: String, schema: String?) -> String? {
        let resolved = schema ?? _currentSchema
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
        let esc = (schema ?? _currentSchema).replacingOccurrences(of: "]", with: "]]")
        let bracketedName = name.replacingOccurrences(of: "]", with: "]]")
        let sql = "SELECT OBJECT_DEFINITION(OBJECT_ID('[\(esc)].[\(bracketedName)]'))"
        let result = try await execute(query: sql)
        guard let definition = result.rows.first?[safe: 0]?.asText, !definition.isEmpty else { return nil }
        guard let range = definition.range(of: "CREATE TRIGGER", options: .caseInsensitive) else {
            return definition
        }
        return definition.replacingCharacters(in: range, with: "CREATE OR ALTER TRIGGER")
    }

    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? {
        let resolved = schema ?? _currentSchema
        return "DROP TRIGGER \(quoteIdentifier(resolved)).\(quoteIdentifier(name))"
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let esc = effectiveSchemaEscaped(schema)
        let sql = """
            SELECT
                c.TABLE_NAME,
                c.COLUMN_NAME,
                c.DATA_TYPE,
                c.CHARACTER_MAXIMUM_LENGTH,
                c.NUMERIC_PRECISION,
                c.NUMERIC_SCALE,
                c.IS_NULLABLE,
                c.COLUMN_DEFAULT,
                COLUMNPROPERTY(OBJECT_ID(c.TABLE_SCHEMA + '.' + c.TABLE_NAME), c.COLUMN_NAME, 'IsIdentity') AS IS_IDENTITY,
                CASE WHEN pk.COLUMN_NAME IS NOT NULL THEN 1 ELSE 0 END AS IS_PK
            FROM INFORMATION_SCHEMA.COLUMNS c
            LEFT JOIN (
                SELECT kcu.TABLE_NAME, kcu.COLUMN_NAME
                FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
                JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
                    ON tc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
                    AND tc.TABLE_SCHEMA = kcu.TABLE_SCHEMA
                WHERE tc.CONSTRAINT_TYPE = 'PRIMARY KEY'
                    AND tc.TABLE_SCHEMA = '\(esc)'
            ) pk ON c.TABLE_NAME = pk.TABLE_NAME AND c.COLUMN_NAME = pk.COLUMN_NAME
            WHERE c.TABLE_SCHEMA = '\(esc)'
            ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION
            """
        let result = try await execute(query: sql)
        var columnsByTable: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard let tableName = row[safe: 0]?.asText,
                  let name = row[safe: 1]?.asText else { continue }
            let dataType = row[safe: 2]?.asText
            let charLen = row[safe: 3]?.asText
            let numPrecision = row[safe: 4]?.asText
            let numScale = row[safe: 5]?.asText
            let isNullable = (row[safe: 6]?.asText) == "YES"
            let defaultValue = row[safe: 7]?.asText
            let isIdentity = (row[safe: 8]?.asText) == "1"
            let isPk = (row[safe: 9]?.asText) == "1"

            let baseType = (dataType ?? "nvarchar").lowercased()
            let fixedSizeTypes: Set<String> = [
                "int", "bigint", "smallint", "tinyint", "bit",
                "money", "smallmoney", "float", "real",
                "datetime", "datetime2", "smalldatetime", "date", "time",
                "uniqueidentifier", "text", "ntext", "image", "xml",
                "timestamp", "rowversion"
            ]
            var fullType = baseType
            if fixedSizeTypes.contains(baseType) {
                // No suffix
            } else if let charLen, let len = Int(charLen), len > 0 {
                fullType += "(\(len))"
            } else if charLen == "-1" {
                fullType += "(max)"
            } else if let prec = numPrecision, let scale = numScale,
                      let p = Int(prec), let s = Int(scale) {
                fullType += "(\(p),\(s))"
            }

            let col = PluginColumnInfo(
                name: name,
                dataType: fullType,
                isNullable: isNullable,
                isPrimaryKey: isPk,
                defaultValue: defaultValue,
                extra: isIdentity ? "IDENTITY" : nil
            )
            columnsByTable[tableName, default: []].append(col)
        }
        return columnsByTable
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        let esc = effectiveSchemaEscaped(schema)
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
            WHERE s.name = '\(esc)'
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

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let sql = """
            SELECT d.name,
                   SUM(mf.size) * 8 * 1024 AS size_bytes
            FROM sys.databases d
            LEFT JOIN sys.master_files mf ON d.database_id = mf.database_id
            GROUP BY d.name
            ORDER BY d.name
            """
        do {
            let result = try await execute(query: sql)
            var metadata = result.rows.compactMap { row -> PluginDatabaseMetadata? in
                guard let name = row[safe: 0]?.asText else { return nil }
                let sizeBytes = (row[safe: 1]?.asText).flatMap { Int64($0) }
                return PluginDatabaseMetadata(name: name, sizeBytes: sizeBytes)
            }

            for i in metadata.indices {
                let dbName = metadata[i].name.replacingOccurrences(of: "]", with: "]]")
                do {
                    let countResult = try await execute(
                        query: "SELECT COUNT(*) FROM [\(dbName)].sys.tables"
                    )
                    if let countStr = countResult.rows.first?[safe: 0]?.asText,
                       let count = Int(countStr) {
                        metadata[i] = PluginDatabaseMetadata(
                            name: metadata[i].name,
                            tableCount: count,
                            sizeBytes: metadata[i].sizeBytes
                        )
                    }
                } catch {
                    // Database offline or permission denied: leave tableCount as nil
                }
            }

            return metadata
        } catch {
            // Fall back to N+1 if permission denied on sys.master_files
            let dbs = try await fetchDatabases()
            var result: [PluginDatabaseMetadata] = []
            for db in dbs {
                do {
                    result.append(try await fetchDatabaseMetadata(db))
                } catch {
                    result.append(PluginDatabaseMetadata(name: db))
                }
            }
            return result
        }
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let esc = effectiveSchemaEscaped(schema)
        let cols = try await fetchColumns(table: table, schema: schema)
        let indexes = try await fetchIndexes(table: table, schema: schema)
        let fks = try await fetchForeignKeys(table: table, schema: schema)

        var ddl = "CREATE TABLE [\(esc)].[\(escapedTable)] (\n"
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
        let esc = effectiveSchemaEscaped(schema)
        let escapedView = "\(esc).\(view.replacingOccurrences(of: "'", with: "''"))"
        let sql = "SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID('\(escapedView)')"
        let result = try await execute(query: sql)
        return result.rows.first?.first?.asText ?? ""
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let esc = effectiveSchemaEscaped(schema)
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
            WHERE t.name = '\(escapedTable)' AND s.name = '\(esc)'
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
        let sql = """
            SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA
            WHERE SCHEMA_NAME NOT IN (
                'information_schema','sys','db_owner','db_accessadmin',
                'db_securityadmin','db_ddladmin','db_backupoperator',
                'db_datareader','db_datawriter','db_denydatareader',
                'db_denydatawriter','guest'
            )
            ORDER BY SCHEMA_NAME
            """
        let result = try await execute(query: sql)
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
        let sql = """
            SELECT
                SUM(size) * 8.0 / 1024 AS size_mb,
                (SELECT COUNT(*) FROM sys.tables) AS table_count
            FROM sys.database_files
            """
        let result = try await execute(query: sql)
        if let row = result.rows.first {
            let sizeMb = (row[safe: 0]?.asText).flatMap { Double($0) } ?? 0
            let tableCount = (row[safe: 1]?.asText).flatMap { Int($0) } ?? 0
            return PluginDatabaseMetadata(
                name: database,
                tableCount: tableCount,
                sizeBytes: Int64(sizeMb * 1_024 * 1_024)
            )
        }
        return PluginDatabaseMetadata(name: database)
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

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        """
        SELECT
            s.name as schema_name,
            t.name as name,
            CASE WHEN v.object_id IS NOT NULL THEN 'VIEW' ELSE 'TABLE' END as kind,
            p.rows as estimated_rows,
            CAST(ROUND(SUM(a.total_pages) * 8 / 1024.0, 2) AS VARCHAR) + ' MB' as total_size
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
