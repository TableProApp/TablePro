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

final class RedshiftPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var libpqConnection: LibPQPluginConnection?
    private var _currentSchema: String = "public"

    private static let logger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "RedshiftPluginDriver")
    private static let limitRegex = try? NSRegularExpression(pattern: "(?i)\\s+LIMIT\\s+\\d+")
    private static let offsetRegex = try? NSRegularExpression(pattern: "(?i)\\s+OFFSET\\s+\\d+")

    var currentSchema: String? { _currentSchema }
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }
    var serverVersion: String? { libpqConnection?.serverVersion() }
    var parameterStyle: ParameterStyle { .dollar }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    private var escapedSchema: String {
        escapeLiteral(_currentSchema)
    }

    private func escapeLiteral(_ str: String) -> String {
        var result = str
        result = result.replacingOccurrences(of: "'", with: "''")
        result = result.replacingOccurrences(of: "\0", with: "")
        return result
    }

    // MARK: - Connection

    func connect() async throws {
        let sslConfig = PQSSLConfig(additionalFields: config.additionalFields)

        let pqConn = LibPQPluginConnection(
            host: config.host,
            port: config.port,
            user: config.username,
            password: config.password.isEmpty ? nil : config.password,
            database: config.database,
            sslConfig: sslConfig
        )

        try await pqConn.connect()
        self.libpqConnection = pqConn

        if let schemaResult = try? await pqConn.executeQuery("SELECT current_schema()"),
           let schema = schemaResult.rows.first?.first.flatMap({ $0 }) {
            _currentSchema = schema
        }
    }

    func disconnect() {
        libpqConnection?.disconnect()
        libpqConnection = nil
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        try await executeWithReconnect(query: query, isRetry: false)
    }

    private func executeWithReconnect(query: String, isRetry: Bool) async throws -> PluginQueryResult {
        guard let pqConn = libpqConnection else {
            throw LibPQPluginError.notConnected
        }

        let startTime = Date()

        do {
            let result = try await pqConn.executeQuery(query)
            return PluginQueryResult(
                columns: result.columns,
                columnTypeNames: result.columnTypeNames,
                rows: result.rows,
                rowsAffected: result.affectedRows,
                executionTime: Date().timeIntervalSince(startTime),
                isTruncated: result.isTruncated
            )
        } catch let error as NSError where !isRetry && isConnectionLostError(error) {
            try await reconnect()
            return try await executeWithReconnect(query: query, isRetry: true)
        }
    }

    func executeParameterized(query: String, parameters: [String?]) async throws -> PluginQueryResult {
        guard let pqConn = libpqConnection else {
            throw LibPQPluginError.notConnected
        }
        let startTime = Date()
        let result = try await pqConn.executeParameterizedQuery(query, parameters: parameters)
        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: result.affectedRows,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: result.isTruncated
        )
    }

    func fetchRowCount(query: String) async throws -> Int {
        let baseQuery = stripLimitOffset(from: query)
        let countQuery = "SELECT COUNT(*) FROM (\(baseQuery)) AS __count_subquery__"
        let result = try await execute(query: countQuery)
        guard let firstRow = result.rows.first, let countStr = firstRow.first else { return 0 }
        return Int(countStr ?? "0") ?? 0
    }

    func fetchFirstPage(query: String, limit: Int) async throws -> PluginPagedResult {
        guard limit > 0 else {
            let result = try await execute(query: query)
            return PluginPagedResult(
                columns: result.columns,
                columnTypeNames: result.columnTypeNames,
                rows: result.rows,
                executionTime: result.executionTime,
                hasMore: false,
                nextOffset: result.rows.count
            )
        }

        if let regex = Self.limitRegex,
           regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)) != nil
        {
            let result = try await execute(query: query)
            return PluginPagedResult(
                columns: result.columns,
                columnTypeNames: result.columnTypeNames,
                rows: result.rows,
                executionTime: result.executionTime,
                hasMore: false,
                nextOffset: result.rows.count
            )
        }

        let baseQuery = stripLimitOffset(from: query)
        let probeQuery = "\(baseQuery) LIMIT \(limit + 1)"
        let result = try await execute(query: probeQuery)

        let hasMore = result.rows.count > limit
        let rows = hasMore ? Array(result.rows.prefix(limit)) : result.rows

        return PluginPagedResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: rows,
            executionTime: result.executionTime,
            hasMore: hasMore,
            nextOffset: rows.count
        )
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        let baseQuery = stripLimitOffset(from: query)
        let paginatedQuery = "\(baseQuery) LIMIT \(limit) OFFSET \(offset)"
        return try await execute(query: paginatedQuery)
    }

    // MARK: - Reconnect

    private func isConnectionLostError(_ error: NSError) -> Bool {
        let errorMessage = error.localizedDescription.lowercased()
        return errorMessage.contains("connection") &&
            (errorMessage.contains("lost") ||
                errorMessage.contains("closed") ||
                errorMessage.contains("no connection") ||
                errorMessage.contains("could not send"))
    }

    private func reconnect() async throws {
        libpqConnection?.disconnect()
        libpqConnection = nil
        try await connect()
    }

    // MARK: - Cancellation

    func cancelQuery() throws {
        libpqConnection?.cancelCurrentQuery()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        let ms = seconds * 1_000
        _ = try await execute(query: "SET statement_timeout = '\(ms)'")
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN \(sql)"
    }

    // MARK: - Schema

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let query = """
            SELECT table_name, table_type
            FROM information_schema.tables
            WHERE table_schema = '\(escapedSchema)'
            ORDER BY table_name
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard let name = row[0] else { return nil }
            let typeStr = row[1] ?? "BASE TABLE"
            let type = typeStr.contains("VIEW") ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: type)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let safeTable = escapeLiteral(table)
        let query = """
            SELECT
                c.column_name,
                c.data_type,
                c.is_nullable,
                c.column_default,
                c.collation_name,
                pgd.description,
                c.udt_name,
                CASE WHEN pk.column_name IS NOT NULL THEN 'YES' ELSE 'NO' END AS is_pk
            FROM information_schema.columns c
            LEFT JOIN pg_catalog.pg_class cls
                ON cls.relname = c.table_name
                AND cls.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = c.table_schema)
            LEFT JOIN pg_catalog.pg_description pgd
                ON pgd.objoid = cls.oid
                AND pgd.objsubid = c.ordinal_position
            LEFT JOIN (
                SELECT DISTINCT kcu.column_name
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                    ON tc.constraint_name = kcu.constraint_name
                    AND tc.table_schema = kcu.table_schema
                WHERE tc.constraint_type = 'PRIMARY KEY'
                    AND tc.table_schema = '\(escapedSchema)'
                    AND tc.table_name = '\(safeTable)'
            ) pk ON c.column_name = pk.column_name
            WHERE c.table_schema = '\(escapedSchema)' AND c.table_name = '\(safeTable)'
            ORDER BY c.ordinal_position
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard row.count >= 4,
                  let name = row[0],
                  let rawDataType = row[1]
            else { return nil }

            let udtName = row.count > 6 ? row[6] : nil
            let dataType: String
            if rawDataType.uppercased() == "USER-DEFINED", let udt = udtName {
                dataType = "ENUM(\(udt))"
            } else {
                dataType = rawDataType.uppercased()
            }

            let isNullable = row[2] == "YES"
            let defaultValue = row[3]
            let collation = row.count > 4 ? row[4] : nil
            let comment = row.count > 5 ? row[5] : nil
            let isPk = row.count > 7 && row[7] == "YES"

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
        let query = """
            SELECT
                c.table_name,
                c.column_name,
                c.data_type,
                c.is_nullable,
                c.column_default,
                c.collation_name,
                pgd.description,
                c.udt_name,
                CASE WHEN pk.column_name IS NOT NULL THEN 'YES' ELSE 'NO' END AS is_pk
            FROM information_schema.columns c
            LEFT JOIN pg_catalog.pg_class cls
                ON cls.relname = c.table_name
                AND cls.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = c.table_schema)
            LEFT JOIN pg_catalog.pg_description pgd
                ON pgd.objoid = cls.oid
                AND pgd.objsubid = c.ordinal_position
            LEFT JOIN (
                SELECT DISTINCT kcu.table_name, kcu.column_name
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                    ON tc.constraint_name = kcu.constraint_name
                    AND tc.table_schema = kcu.table_schema
                WHERE tc.constraint_type = 'PRIMARY KEY'
                    AND tc.table_schema = '\(escapedSchema)'
            ) pk ON c.table_name = pk.table_name AND c.column_name = pk.column_name
            WHERE c.table_schema = '\(escapedSchema)'
            ORDER BY c.table_name, c.ordinal_position
            """
        let result = try await execute(query: query)
        var allColumns: [String: [PluginColumnInfo]] = [:]
        for row in result.rows {
            guard row.count >= 5,
                  let tableName = row[0],
                  let name = row[1],
                  let rawDataType = row[2]
            else { continue }

            let udtName = row.count > 7 ? row[7] : nil
            let dataType: String
            if rawDataType.uppercased() == "USER-DEFINED", let udt = udtName {
                dataType = "ENUM(\(udt))"
            } else {
                dataType = rawDataType.uppercased()
            }

            let isNullable = row[3] == "YES"
            let defaultValue = row[4]
            let collation = row.count > 5 ? row[5] : nil
            let comment = row.count > 6 ? row[6] : nil
            let isPk = row.count > 8 && row[8] == "YES"

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
        let query = """
            SELECT
                "column",
                type,
                distkey,
                sortkey
            FROM pg_table_def
            WHERE schemaname = '\(escapedSchema)'
              AND tablename = '\(safeTable)'
              AND (distkey = true OR sortkey != 0)
            ORDER BY sortkey
            """
        let result = try await execute(query: query)

        var distkeyCols: [String] = []
        var sortkeyCols: [String] = []
        for row in result.rows {
            guard let colName = row[0] else { continue }
            let isDistkey = row[2] == "t"
            let sortKeyVal = Int(row[3] ?? "0") ?? 0
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
        return result.rows.compactMap { row in
            guard row.count >= 6,
                  let name = row[0],
                  let column = row[1],
                  let refTable = row[2],
                  let refColumn = row[3]
            else { return nil }
            return PluginForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: refTable,
                referencedColumn: refColumn,
                onDelete: row[4] ?? "NO ACTION",
                onUpdate: row[5] ?? "NO ACTION"
            )
        }
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let safeTable = escapeLiteral(table)
        let query = """
            SELECT tbl_rows
            FROM svv_table_info
            WHERE "table" = '\(safeTable)'
              AND schema = '\(escapedSchema)'
            """
        let result = try await execute(query: query)
        guard let firstRow = result.rows.first, let value = firstRow[0], let count = Int(value) else { return nil }
        return count >= 0 ? count : nil
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let safeTable = escapeLiteral(table)
        let quotedTable = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
        let quotedSchema = "\"\(_currentSchema.replacingOccurrences(of: "\"", with: "\"\""))\""

        do {
            let showResult = try await execute(query: "SHOW TABLE \(quotedSchema).\(quotedTable)")
            if let firstRow = showResult.rows.first, let ddl = firstRow[0], !ddl.isEmpty {
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
              AND n.nspname = '\(escapedSchema)'
              AND a.attnum > 0
              AND NOT a.attisdropped
            ORDER BY a.attnum
            """
        let columnsResult = try await execute(query: columnsQuery)
        let columnDefs = columnsResult.rows.compactMap { $0[0] }
        guard !columnDefs.isEmpty else {
            throw LibPQPluginError(message: "Failed to fetch DDL for table '\(table)'", sqlState: nil, detail: nil)
        }

        let ddl = "CREATE TABLE \(quotedSchema).\(quotedTable) (\n  " +
            columnDefs.joined(separator: ",\n  ") +
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

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let safeView = escapeLiteral(view)
        let query = """
            SELECT 'CREATE OR REPLACE VIEW ' || quote_ident(schemaname) || '.' || quote_ident(viewname) || ' AS ' || E'\\n' || definition AS ddl
            FROM pg_views
            WHERE viewname = '\(safeView)'
              AND schemaname = '\(escapedSchema)'
            """
        let result = try await execute(query: query)
        guard let firstRow = result.rows.first, let ddl = firstRow[0] else {
            throw LibPQPluginError(message: "Failed to fetch definition for view '\(view)'", sqlState: nil, detail: nil)
        }
        return ddl
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let safeTable = escapeLiteral(table)
        let query = """
            SELECT
                tbl_rows,
                size AS size_mb,
                pct_used,
                unsorted,
                stats_off
            FROM svv_table_info
            WHERE "table" = '\(safeTable)'
              AND schema = '\(escapedSchema)'
            """
        let result = try await execute(query: query)
        guard let row = result.rows.first else {
            return PluginTableMetadata(tableName: table)
        }

        let rowCount: Int64? = {
            guard let val = row[0] else { return nil }
            return Int64(val)
        }()

        let sizeMb = Int64(row[1] ?? "0") ?? 0
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
        return result.rows.compactMap { row in row.first.flatMap { $0 } }
    }

    func fetchSchemas() async throws -> [String] {
        let result = try await execute(query: """
            SELECT schema_name FROM information_schema.schemata
            WHERE schema_name NOT LIKE 'pg_%'
              AND schema_name <> 'information_schema'
            ORDER BY schema_name
            """)
        return result.rows.compactMap { row in row.first.flatMap { $0 } }
    }

    func switchSchema(to schema: String) async throws {
        let escapedName = schema.replacingOccurrences(of: "\"", with: "\"\"")
        _ = try await execute(query: "SET search_path TO \"\(escapedName)\", public")
        _currentSchema = schema
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

        let tableCount = Int(countRes.rows.first?[0] ?? "0") ?? 0
        let sizeMb = Int64(sizeRes.rows.first?[0] ?? "0") ?? 0
        let sizeBytes = sizeMb * 1_024 * 1_024

        let systemDatabases = ["dev", "padb_harvest"]
        let isSystem = systemDatabases.contains(database)

        return PluginDatabaseMetadata(
            name: database,
            tableCount: tableCount,
            sizeBytes: sizeBytes,
            isSystemDatabase: isSystem
        )
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let systemDatabases = ["dev", "padb_harvest"]
        let dbResult = try await execute(
            query: "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
        )
        let dbNames = dbResult.rows.compactMap { $0.first.flatMap { $0 } }

        let infoQuery = """
            SELECT database, COUNT(DISTINCT "table"), COALESCE(SUM(size), 0)
            FROM svv_table_info
            WHERE schema NOT IN ('pg_internal', 'pg_catalog', 'information_schema')
            GROUP BY database
            """
        let infoResult = try await execute(query: infoQuery)
        var metadataByName: [String: (tableCount: Int, sizeMb: Int64)] = [:]
        for row in infoResult.rows {
            guard let dbName = row[0] else { continue }
            let tableCount = Int(row[1] ?? "0") ?? 0
            let sizeMb = Int64(row[2] ?? "0") ?? 0
            metadataByName[dbName] = (tableCount: tableCount, sizeMb: sizeMb)
        }

        return dbNames.map { dbName in
            let isSystem = systemDatabases.contains(dbName)
            let info = metadataByName[dbName]
            return PluginDatabaseMetadata(
                name: dbName,
                tableCount: info?.tableCount,
                sizeBytes: info.map { $0.sizeMb * 1_024 * 1_024 },
                isSystemDatabase: isSystem
            )
        }
    }

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        let escapedName = name.replacingOccurrences(of: "\"", with: "\"\"")
        let validCharsets = ["UTF8", "LATIN1", "SQL_ASCII", "WIN1252", "EUC_JP",
                              "EUC_KR", "ISO_8859_5", "KOI8R", "SJIS", "BIG5", "GBK"]
        let normalizedCharset = charset.uppercased()
        guard validCharsets.contains(normalizedCharset) else {
            throw LibPQPluginError(message: "Invalid encoding: \(charset)", sqlState: nil, detail: nil)
        }

        var query = "CREATE DATABASE \"\(escapedName)\" ENCODING '\(normalizedCharset)'"
        if let collation = collation {
            let allowedCollationChars = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"
            )
            let isValidCollation = collation.unicodeScalars.allSatisfy { allowedCollationChars.contains($0) }
            guard isValidCollation else {
                throw LibPQPluginError(message: "Invalid collation", sqlState: nil, detail: nil)
            }
            let escapedCollation = collation.replacingOccurrences(of: "'", with: "''")
            query += " LC_COLLATE '\(escapedCollation)'"
        }
        _ = try await execute(query: query)
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

    // MARK: - Helpers

    private func stripLimitOffset(from query: String) -> String {
        var result = query
        if let regex = Self.limitRegex {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        if let regex = Self.offsetRegex {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
