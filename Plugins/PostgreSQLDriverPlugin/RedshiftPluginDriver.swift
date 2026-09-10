//
//  RedshiftPluginDriver.swift
//  PostgreSQLDriverPlugin
//
//  Amazon Redshift PluginDatabaseDriver implementation.
//  Adapted from TablePro's RedshiftDriver for the plugin architecture.
//

import Foundation
import os
import TableProPluginKit

final class RedshiftPluginDriver: LibPQBackedDriver, @unchecked Sendable {
    let core: LibPQDriverCore

    private let connectedDatabase: String

    private var externalSchemaCache: Set<String>?

    private static let logger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "RedshiftPluginDriver")

    var capabilities: PluginCapabilities {
        [
            .parameterizedQueries,
            .transactions,
            .multiSchema,
            .cancelQuery,
            .batchExecute,
            .schemaCompare,
            .dataCompare,
        ]
    }

    init(config: DriverConnectionConfig) {
        self.connectedDatabase = config.database
        self.core = LibPQDriverCore(
            config: config,
            schemaFallbackQueries: PostgreSQLSchemaQueries.schemaFallbackQueriesRedshift
        )
        core.onPostConnect = { [weak self] in
            await self?.probeExternalSchemas()
        }
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN \(sql)"
    }

    // MARK: - Schema

    /// Refreshed from `onPostConnect` and whenever the schema list is loaded, so
    /// a schema created mid-session is classified without a reconnect. A failed
    /// probe leaves the previous answer in place rather than replacing it with
    /// an empty one. A cluster with no external catalog answers in one cheap read.
    private func probeExternalSchemas() async {
        do {
            let result = try await execute(query: RedshiftExternalSchemaQueries.listExternalSchemaNames)
            externalSchemaCache = Set(result.rows.compactMap { $0.first?.asText })
        } catch {
            Self.logger.warning(
                "Could not read svv_external_schemas; external schemas stay unresolved: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func fetchExternalSchemaNames() async throws -> Set<String> {
        externalSchemaCache ?? []
    }

    private func isExternalSchema(_ schema: String) -> Bool {
        externalSchemaCache?.contains(schema) ?? false
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let resolvedSchema = schema ?? core.currentSchema
        let schemaLiteral = escapeLiteral(resolvedSchema)
        let query = """
            SELECT table_name, table_type
            FROM information_schema.tables
            WHERE table_schema = '\(schemaLiteral)'
            ORDER BY table_name
            """
        let result = try await execute(query: query)
        let localTables = result.rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[0].asText else { return nil }
            let typeStr = row[1].asText ?? "BASE TABLE"
            let type = typeStr.contains("VIEW") ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: type)
        }

        guard isExternalSchema(resolvedSchema) else { return localTables }

        let externalTables = await fetchExternalTables(schemaLiteral: schemaLiteral, schema: resolvedSchema)
        guard !externalTables.isEmpty else { return localTables }

        let localNames = Set(localTables.map(\.name))
        let merged = localTables + externalTables.filter { !localNames.contains($0.name) }
        return merged.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func fetchExternalTables(schemaLiteral: String, schema: String) async -> [PluginTableInfo] {
        do {
            let result = try await execute(
                query: RedshiftExternalSchemaQueries.listExternalTables(
                    schemaLiteral: schemaLiteral,
                    databaseLiteral: escapeLiteral(connectedDatabase)
                )
            )
            return result.rows.compactMap { row -> PluginTableInfo? in
                guard let name = row[0].asText else { return nil }
                let rawType = row.count > 1 ? row[1].asText : nil
                return PluginTableInfo(
                    name: name,
                    type: RedshiftExternalSchemaQueries.classifyTableType(rawTabletype: rawType),
                    schema: schema
                )
            }
        } catch {
            Self.logger.warning(
                "svv_external_tables failed for schema \(schema, privacy: .public); listing local tables only: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let resolvedSchema = schema ?? core.currentSchema
        if isExternalSchema(resolvedSchema) {
            let external = await fetchExternalColumns(
                schemaLiteral: escapeLiteral(resolvedSchema),
                tableLiteral: escapeLiteral(table),
                schema: resolvedSchema
            )
            if !external.isEmpty { return external }
        }
        return try await fetchLocalColumns(table: table, schema: resolvedSchema)
    }

    private func fetchExternalColumns(
        schemaLiteral: String,
        tableLiteral: String,
        schema: String
    ) async -> [PluginColumnInfo] {
        do {
            let result = try await execute(
                query: RedshiftExternalSchemaQueries.listExternalColumns(
                    schemaLiteral: schemaLiteral,
                    tableLiteral: tableLiteral,
                    databaseLiteral: escapeLiteral(connectedDatabase)
                )
            )
            return result.rows.compactMap { row -> PluginColumnInfo? in
                guard row.count >= 2, let name = row[0].asText, let dataType = row[1].asText else { return nil }
                return Self.externalColumn(name: name, dataType: dataType, row: row, typeIndex: 1)
            }
        } catch {
            Self.logger.warning(
                "svv_external_columns failed for schema \(schema, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    /// External columns carry no default, charset, collation, comment, or key
    /// information, and `external_type` is an opaque Hive type string that must
    /// reach the UI unparsed so nested `struct`/`array` declarations survive.
    private static func externalColumn(
        name: String,
        dataType: String,
        row: [PluginCellValue],
        typeIndex: Int
    ) -> PluginColumnInfo {
        let nullableIndex = typeIndex + 1
        let partKeyIndex = typeIndex + 2
        let rawNullable = row.count > nullableIndex ? row[nullableIndex].asText : nil
        let rawPartKey = row.count > partKeyIndex ? row[partKeyIndex].asText : nil
        return PluginColumnInfo(
            name: name,
            dataType: dataType,
            isNullable: RedshiftExternalSchemaQueries.classifyIsNullable(raw: rawNullable),
            isPrimaryKey: false,
            extra: RedshiftExternalSchemaQueries.partitionKeyDescription(rawPartKey: rawPartKey)
        )
    }

    private func fetchLocalColumns(table: String, schema: String) async throws -> [PluginColumnInfo] {
        let schemaLiteral = escapeLiteral(schema)
        let query = RedshiftSchemaQueries.columnsQuery(
            schemaLiteral: schemaLiteral,
            tableLiteral: escapeLiteral(table)
        )
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginColumnInfo? in
            guard row.count >= 4,
                  let name = row[0].asText,
                  let rawDataType = row[1].asText
            else { return nil }

            let udtName = row.count > 6 ? row[6].asText : nil
            let dataType: String
            if rawDataType.uppercased() == "USER-DEFINED", let udt = udtName {
                dataType = "ENUM(\(udt))"
            } else {
                dataType = rawDataType.uppercased()
            }

            let isNullable = row[2].asText == "YES"
            let defaultValue = row[3].asText
            let collation = row.count > 4 ? row[4].asText : nil
            let comment = row.count > 5 ? row[5].asText : nil
            let isPk = row.count > 7 && row[7].asText == "YES"

            let charset: String? = {
                guard let coll = collation else { return nil }
                if coll.contains(".") {
                    return coll.components(separatedBy: ".").last
                }
                return nil
            }()

            return PluginColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPk,
                defaultValue: defaultValue,
                charset: charset,
                collation: collation,
                comment: comment?.isEmpty == false ? comment : nil
            )
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let resolvedSchema = schema ?? core.currentSchema
        if isExternalSchema(resolvedSchema) {
            let external = await fetchExternalAllColumns(
                schemaLiteral: escapeLiteral(resolvedSchema),
                schema: resolvedSchema
            )
            if !external.isEmpty { return external }
        }
        return try await fetchLocalAllColumns(schema: resolvedSchema)
    }

    private func fetchExternalAllColumns(
        schemaLiteral: String,
        schema: String
    ) async -> [String: [PluginColumnInfo]] {
        do {
            let result = try await execute(
                query: RedshiftExternalSchemaQueries.listExternalColumns(
                    schemaLiteral: schemaLiteral,
                    tableLiteral: nil,
                    databaseLiteral: escapeLiteral(connectedDatabase)
                )
            )
            var allColumns: [String: [PluginColumnInfo]] = [:]
            for row in result.rows {
                guard row.count >= 3,
                      let tableName = row[0].asText,
                      let name = row[1].asText,
                      let dataType = row[2].asText
                else { continue }
                let column = Self.externalColumn(name: name, dataType: dataType, row: row, typeIndex: 2)
                allColumns[tableName, default: []].append(column)
            }
            return allColumns
        } catch {
            Self.logger.warning(
                "svv_external_columns failed for schema \(schema, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }

    private func fetchLocalAllColumns(schema: String) async throws -> [String: [PluginColumnInfo]] {
        let schemaLiteral = escapeLiteral(schema)
        let query = RedshiftSchemaQueries.columnsQuery(schemaLiteral: schemaLiteral, tableLiteral: nil)
        let result = try await execute(query: query)
        var allColumns: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard row.count >= 5,
                  let tableName = row[0].asText,
                  let name = row[1].asText,
                  let rawDataType = row[2].asText
            else { continue }

            let udtName = row.count > 7 ? row[7].asText : nil
            let dataType: String
            if rawDataType.uppercased() == "USER-DEFINED", let udt = udtName {
                dataType = "ENUM(\(udt))"
            } else {
                dataType = rawDataType.uppercased()
            }

            let isNullable = row[3].asText == "YES"
            let defaultValue = row[4].asText
            let collation = row.count > 5 ? row[5].asText : nil
            let comment = row.count > 6 ? row[6].asText : nil
            let isPk = row.count > 8 && row[8].asText == "YES"

            let charset: String? = {
                guard let coll = collation else { return nil }
                if coll.contains(".") {
                    return coll.components(separatedBy: ".").last
                }
                return nil
            }()

            let column = PluginColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPk,
                defaultValue: defaultValue,
                charset: charset,
                collation: collation,
                comment: comment?.isEmpty == false ? comment : nil
            )
            allColumns[tableName, default: []].append(column)
        }
        return allColumns
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let safeTable = escapeLiteral(table)
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        let query = """
            SELECT
                "column",
                type,
                distkey,
                sortkey
            FROM pg_table_def
            WHERE schemaname = '\(schemaLiteral)'
              AND tablename = '\(safeTable)'
              AND (distkey = true OR sortkey != 0)
            ORDER BY sortkey
            """
        let result = try await execute(query: query)

        var distkeyCols: [String] = []
        var sortkeyCols: [String] = []
        for row in result.rows {
            guard let colName = row[0].asText else { continue }
            let isDistkey = row[2].asText == "t"
            let sortKeyVal = Int(row[3].asText ?? "0") ?? 0
            if isDistkey { distkeyCols.append(colName) }
            if sortKeyVal != 0 { sortkeyCols.append(colName) }
        }

        var indexes: [PluginIndexInfo] = []
        if !distkeyCols.isEmpty {
            indexes.append(PluginIndexInfo(name: "DISTKEY", columns: distkeyCols, type: "DISTKEY"))
        }
        if !sortkeyCols.isEmpty {
            indexes.append(PluginIndexInfo(name: "SORTKEY", columns: sortkeyCols, type: "SORTKEY"))
        }
        return indexes
    }

    var tableDDLIncludesForeignKeys: Bool { true }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let safeTable = escapeLiteral(table)
        let query = """
            SELECT
                tc.constraint_name,
                kcu.column_name,
                ccu.table_name AS referenced_table,
                ccu.column_name AS referenced_column,
                rc.delete_rule,
                rc.update_rule
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
            JOIN information_schema.referential_constraints rc
                ON tc.constraint_name = rc.constraint_name
            JOIN information_schema.constraint_column_usage ccu
                ON rc.unique_constraint_name = ccu.constraint_name
            WHERE tc.table_name = '\(safeTable)'
                AND tc.constraint_type = 'FOREIGN KEY'
            ORDER BY tc.constraint_name
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginForeignKeyInfo? in
            guard row.count >= 6,
                  let name = row[0].asText,
                  let column = row[1].asText,
                  let refTable = row[2].asText,
                  let refColumn = row[3].asText
            else { return nil }
            return PluginForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: refTable,
                referencedColumn: refColumn,
                onDelete: row[4].asText ?? "NO ACTION",
                onUpdate: row[5].asText ?? "NO ACTION"
            )
        }
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let resolvedSchema = schema ?? core.currentSchema
        guard !isExternalSchema(resolvedSchema) else { return nil }
        let safeTable = escapeLiteral(table)
        let schemaLiteral = escapeLiteral(resolvedSchema)
        let query = """
            SELECT tbl_rows
            FROM svv_table_info
            WHERE "table" = '\(safeTable)'
              AND schema = '\(schemaLiteral)'
            """
        let result = try await execute(query: query)
        guard let firstRow = result.rows.first, let value = firstRow[0].asText, let count = Int(value) else { return nil }
        return count >= 0 ? count : nil
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let safeTable = escapeLiteral(table)
        let resolvedSchema = schema ?? core.currentSchema
        let schemaLiteral = escapeLiteral(resolvedSchema)
        let quotedTable = quoteIdentifier(table)
        let quotedSchema = quoteIdentifier(resolvedSchema)

        do {
            let showResult = try await execute(query: "SHOW TABLE \(quotedSchema).\(quotedTable)")
            if let firstRow = showResult.rows.first, let ddl = firstRow[0].asText, !ddl.isEmpty {
                return ddl
            }
        } catch {
            Self.logger.debug("SHOW TABLE not available, falling back to manual reconstruction")
        }

        let columnsQuery = """
            SELECT
                quote_ident(a.attname) || ' ' || format_type(a.atttypid, a.atttypmod) ||
                CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END ||
                CASE WHEN a.atthasdef THEN ' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid) ELSE '' END
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
            WHERE c.relname = '\(safeTable)'
              AND n.nspname = '\(schemaLiteral)'
              AND a.attnum > 0
              AND NOT a.attisdropped
            ORDER BY a.attnum
            """
        let columnsResult = try await execute(query: columnsQuery)
        let columnDefs = columnsResult.rows.compactMap { $0[0].asText }
        guard !columnDefs.isEmpty else {
            throw LibPQPluginError(message: "Failed to fetch DDL for table '\(table)'", sqlState: nil, detail: nil)
        }

        var parts = columnDefs
        parts.append(contentsOf: try await foreignKeyClauses(table: table, schema: schema))

        let ddl = "CREATE TABLE \(quotedSchema).\(quotedTable) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n);"

        do {
            let indexes = try await fetchIndexes(table: table, schema: schema)
            var suffixes: [String] = []
            for idx in indexes {
                if idx.type == "DISTKEY", let col = idx.columns.first {
                    suffixes.append("DISTKEY(\(col))")
                }
                if idx.type == "SORTKEY" {
                    suffixes.append("SORTKEY(\(idx.columns.joined(separator: ", ")))")
                }
            }
            if !suffixes.isEmpty {
                return ddl + "\n" + suffixes.joined(separator: "\n") + ";"
            }
        } catch {
            Self.logger.debug("Could not fetch DISTKEY/SORTKEY info: \(error.localizedDescription)")
        }
        return ddl
    }

    /// `SHOW TABLE` declares foreign keys inline, so the reconstruction below has to as well or
    /// `tableDDLIncludesForeignKeys` would be true of one path and false of the other, and a SQL
    /// export would drop every constraint whenever the fallback ran. A failed lookup therefore
    /// throws rather than returning nothing, because nothing here is indistinguishable from a
    /// table that has no foreign keys.
    private func foreignKeyClauses(table: String, schema: String?) async throws -> [String] {
        let foreignKeys = try await fetchForeignKeys(table: table, schema: schema)
        var orderedNames: [String] = []
        var grouped: [String: [PluginForeignKeyInfo]] = [:]
        for foreignKey in foreignKeys {
            if grouped[foreignKey.name] == nil { orderedNames.append(foreignKey.name) }
            grouped[foreignKey.name, default: []].append(foreignKey)
        }
        return orderedNames.compactMap { name in
            guard let group = grouped[name], let first = group.first else { return nil }
            let columns = group.map { quoteIdentifier($0.column) }.joined(separator: ", ")
            let referencedColumns = group.map { quoteIdentifier($0.referencedColumn) }.joined(separator: ", ")
            let referencedSchema = first.referencedSchema.flatMap { $0.isEmpty ? nil : $0 }
            let referencedTable = referencedSchema.map {
                "\(quoteIdentifier($0)).\(quoteIdentifier(first.referencedTable))"
            } ?? quoteIdentifier(first.referencedTable)
            return "CONSTRAINT \(quoteIdentifier(name)) FOREIGN KEY (\(columns))"
                + " REFERENCES \(referencedTable) (\(referencedColumns))"
        }
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let safeView = escapeLiteral(view)
        let schemaLiteral = escapeLiteral(schema ?? core.currentSchema)
        let query = """
            SELECT 'CREATE OR REPLACE VIEW ' || quote_ident(schemaname) || '.' || quote_ident(viewname) || ' AS ' || E'\\n' || definition AS ddl
            FROM pg_views
            WHERE viewname = '\(safeView)'
              AND schemaname = '\(schemaLiteral)'
            """
        let result = try await execute(query: query)
        guard let firstRow = result.rows.first, let ddl = firstRow[0].asText else {
            throw LibPQPluginError(message: "Failed to fetch definition for view '\(view)'", sqlState: nil, detail: nil)
        }
        return ddl
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let resolvedSchema = schema ?? core.currentSchema
        guard !isExternalSchema(resolvedSchema) else {
            return PluginTableMetadata(tableName: table, engine: "Redshift External")
        }
        let safeTable = escapeLiteral(table)
        let schemaLiteral = escapeLiteral(resolvedSchema)
        let query = """
            SELECT
                tbl_rows,
                size AS size_mb,
                pct_used,
                unsorted,
                stats_off
            FROM svv_table_info
            WHERE "table" = '\(safeTable)'
              AND schema = '\(schemaLiteral)'
            """
        let result = try await execute(query: query)
        guard let row = result.rows.first else {
            return PluginTableMetadata(tableName: table)
        }

        let rowCount: Int64? = {
            guard let val = row[0].asText else { return nil }
            return Int64(val)
        }()

        let sizeMb = Int64(row[1].asText ?? "0") ?? 0
        let totalSize = sizeMb * 1_024 * 1_024

        return PluginTableMetadata(
            tableName: table,
            dataSize: totalSize,
            totalSize: totalSize,
            rowCount: rowCount,
            engine: "Redshift"
        )
    }

    func fetchDatabases() async throws -> [String] {
        let result = try await execute(
            query: "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
        )
        return result.rows.compactMap { row in row.first?.asText }
    }

    func fetchSchemas() async throws -> [String] {
        let result = try await execute(query: PostgreSQLSchemaQueries.listSchemasRedshift)
        await probeExternalSchemas()
        return result.rows.compactMap { row in row.first?.asText }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let escapedDbLiteral = escapeLiteral(database)
        let countQuery = """
            SELECT COUNT(DISTINCT "table") AS table_count
            FROM svv_table_info
            WHERE schema NOT IN ('pg_internal', 'pg_catalog', 'information_schema')
              AND database = '\(escapedDbLiteral)'
            """
        let sizeQuery = """
            SELECT SUM(size) FROM svv_table_info WHERE database = current_database()
            """
        async let countResult = execute(query: countQuery)
        async let sizeResult = execute(query: sizeQuery)
        let (countRes, sizeRes) = try await (countResult, sizeResult)

        let tableCount = Int(countRes.rows.first?[0].asText ?? "0") ?? 0
        let sizeMb = Int64(sizeRes.rows.first?[0].asText ?? "0") ?? 0
        let sizeBytes = sizeMb * 1_024 * 1_024

        return PluginDatabaseMetadata(
            name: database,
            tableCount: tableCount,
            sizeBytes: sizeBytes,
            isSystemDatabase: PostgreSQLSystemDatabases.redshift.contains(database)
        )
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let dbResult = try await execute(
            query: "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
        )
        let dbNames = dbResult.rows.compactMap { $0.first?.asText }

        let infoQuery = """
            SELECT database, COUNT(DISTINCT "table"), COALESCE(SUM(size), 0)
            FROM svv_table_info
            WHERE schema NOT IN ('pg_internal', 'pg_catalog', 'information_schema')
            GROUP BY database
            """
        let infoResult = try await execute(query: infoQuery)
        var metadataByName: [String: (tableCount: Int, sizeMb: Int64)] = [:]
        for row in infoResult.rows {
            guard let dbName = row[0].asText else { continue }
            let tableCount = Int(row[1].asText ?? "0") ?? 0
            let sizeMb = Int64(row[2].asText ?? "0") ?? 0
            metadataByName[dbName] = (tableCount: tableCount, sizeMb: sizeMb)
        }

        return dbNames.map { dbName in
            let info = metadataByName[dbName]
            return PluginDatabaseMetadata(
                name: dbName,
                tableCount: info?.tableCount,
                sizeBytes: info.map { $0.sizeMb * 1_024 * 1_024 },
                isSystemDatabase: PostgreSQLSystemDatabases.redshift.contains(dbName)
            )
        }
    }

    private static let supportedCollations: [String] = ["CASE_SENSITIVE", "CASE_INSENSITIVE"]

    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? {
        let options = Self.supportedCollations.map {
            PluginCreateDatabaseFormSpec.Option(value: $0, label: $0)
        }
        let field = PluginCreateDatabaseFormSpec.Field(
            id: "collate",
            label: String(localized: "Collation"),
            kind: .picker(options: options, defaultValue: "CASE_SENSITIVE")
        )
        return PluginCreateDatabaseFormSpec(fields: [field])
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        guard let collate = request.values["collate"] else {
            throw LibPQPluginError(
                message: String(localized: "Collation is required"),
                sqlState: nil,
                detail: nil
            )
        }
        guard Self.supportedCollations.contains(collate) else {
            throw LibPQPluginError(
                message: String(format: String(localized: "Invalid collation: %@"), collate),
                sqlState: nil,
                detail: nil
            )
        }

        let sql = "CREATE DATABASE \(quoteIdentifier(request.name)) COLLATE \(collate)"
        _ = try await execute(query: sql)
    }

    func dropDatabase(name: String) async throws {
        _ = try await execute(query: "DROP DATABASE \(quoteIdentifier(name))")
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        let s = schema ?? currentSchema ?? "public"
        return """
        SELECT
            schema,
            "table" as name,
            'TABLE' as kind,
            tbl_rows as estimated_rows,
            size as size_mb,
            pct_used,
            unsorted,
            stats_off
        FROM svv_table_info
        WHERE schema = '\(s)'
        ORDER BY "table"
        """
    }
}
