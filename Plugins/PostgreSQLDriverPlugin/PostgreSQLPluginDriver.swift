//
//  PostgreSQLPluginDriver.swift
//  PostgreSQLDriverPlugin
//
//  PostgreSQL PluginDatabaseDriver implementation.
//  Adapted from TablePro's PostgreSQLDriver for the plugin architecture.
//

import Foundation
import os
import TableProPluginKit

final class PostgreSQLPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var libpqConnection: LibPQPluginConnection?
    private var _currentSchema: String = "public"

    private static let logger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "PostgreSQLPluginDriver")
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

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let pqConn = libpqConnection else {
            return AsyncThrowingStream { $0.finish(throwing: LibPQPluginError.notConnected) }
        }
        let baseQuery = stripLimitOffset(from: query)
        return pqConn.streamQuery(baseQuery)
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

    // MARK: - Maintenance

    func supportedMaintenanceOperations() -> [String]? {
        ["VACUUM", "ANALYZE", "REINDEX", "CLUSTER"]
    }

    func maintenanceStatements(operation: String, table: String?, schema: String?, options: [String: String]) -> [String]? {
        let target = table.map { quoteIdentifier($0) }
        switch operation {
        case "VACUUM":
            var opts: [String] = []
            if options["full"] == "true" { opts.append("FULL") }
            if options["analyze"] == "true" { opts.append("ANALYZE") }
            if options["verbose"] == "true" { opts.append("VERBOSE") }
            let optClause = opts.isEmpty ? "" : "(\(opts.joined(separator: ", "))) "
            return [target.map { "VACUUM \(optClause)\($0)" } ?? "VACUUM"]
        case "ANALYZE":
            return [target.map { "ANALYZE \($0)" } ?? "ANALYZE"]
        case "REINDEX":
            return [target.map { "REINDEX TABLE \($0)" } ?? "REINDEX DATABASE CONCURRENTLY"]
        case "CLUSTER":
            return target.map { ["CLUSTER \($0)"] }
        default:
            return nil
        }
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "CREATE OR REPLACE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let quoted = quoteIdentifier(viewName)
        return "CREATE OR REPLACE VIEW \(quoted) AS\nSELECT * FROM table_name;"
    }

    func castColumnToText(_ column: String) -> String {
        "CAST(\(column) AS TEXT)"
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
            LEFT JOIN pg_catalog.pg_statio_all_tables st
                ON st.schemaname = c.table_schema
                AND st.relname = c.table_name
            LEFT JOIN pg_catalog.pg_description pgd
                ON pgd.objoid = st.relid
                AND pgd.objsubid = c.ordinal_position
            LEFT JOIN (
                SELECT DISTINCT kcu.column_name
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                    ON tc.constraint_name = kcu.constraint_name
                    AND tc.table_schema = kcu.table_schema
                WHERE tc.constraint_type = 'PRIMARY KEY'
                    AND tc.table_schema = '\(escapedSchema)'
                    AND tc.table_name = '\(escapeLiteral(table))'
            ) pk ON c.column_name = pk.column_name
            WHERE c.table_schema = '\(escapedSchema)' AND c.table_name = '\(escapeLiteral(table))'
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
            LEFT JOIN pg_catalog.pg_statio_all_tables st
                ON st.schemaname = c.table_schema
                AND st.relname = c.table_name
            LEFT JOIN pg_catalog.pg_description pgd
                ON pgd.objoid = st.relid
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
        let query = """
            SELECT
                i.relname AS index_name,
                ARRAY_AGG(a.attname ORDER BY array_position(ix.indkey, a.attnum)) AS columns,
                ix.indisunique AS is_unique,
                ix.indisprimary AS is_primary,
                am.amname AS index_type,
                pg_get_expr(ix.indpred, ix.indrelid) AS predicate
            FROM pg_index ix
            JOIN pg_class i ON i.oid = ix.indexrelid
            JOIN pg_class t ON t.oid = ix.indrelid
            JOIN pg_am am ON am.oid = i.relam
            JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
            WHERE t.relname = '\(escapeLiteral(table))'
            GROUP BY i.relname, ix.indisunique, ix.indisprimary, am.amname, ix.indpred, ix.indrelid
            ORDER BY ix.indisprimary DESC, i.relname
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard row.count >= 5, let name = row[0], let columnsStr = row[1] else { return nil }
            let columns = columnsStr
                .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                .components(separatedBy: ",")
            let whereClause = row.count > 5 ? row[5] : nil
            return PluginIndexInfo(
                name: name,
                columns: columns,
                isUnique: row[2] == "t",
                isPrimary: row[3] == "t",
                type: row[4]?.uppercased() ?? "BTREE",
                whereClause: whereClause
            )
        }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let query = """
            SELECT
                tc.constraint_name,
                kcu.column_name,
                ccu.table_name AS referenced_table,
                ccu.column_name AS referenced_column,
                ccu.table_schema AS referenced_schema,
                rc.delete_rule,
                rc.update_rule
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
                AND tc.table_schema = kcu.table_schema
            JOIN information_schema.referential_constraints rc
                ON tc.constraint_name = rc.constraint_name
                AND tc.constraint_schema = rc.constraint_schema
            JOIN information_schema.constraint_column_usage ccu
                ON rc.unique_constraint_name = ccu.constraint_name
                AND rc.unique_constraint_schema = ccu.constraint_schema
            WHERE tc.table_name = '\(escapeLiteral(table))'
                AND tc.table_schema = '\(escapedSchema)'
                AND tc.constraint_type = 'FOREIGN KEY'
            ORDER BY tc.constraint_name
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard row.count >= 7,
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
                referencedSchema: row[4],
                onDelete: row[5] ?? "NO ACTION",
                onUpdate: row[6] ?? "NO ACTION"
            )
        }
    }

    func fetchAllForeignKeys(schema: String?) async throws -> [String: [PluginForeignKeyInfo]] {
        let query = """
            SELECT
                tc.table_name,
                tc.constraint_name,
                kcu.column_name,
                ccu.table_name AS referenced_table,
                ccu.column_name AS referenced_column,
                ccu.table_schema AS referenced_schema,
                rc.delete_rule,
                rc.update_rule
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
                AND tc.table_schema = kcu.table_schema
            JOIN information_schema.referential_constraints rc
                ON tc.constraint_name = rc.constraint_name
                AND tc.constraint_schema = rc.constraint_schema
            JOIN information_schema.constraint_column_usage ccu
                ON rc.unique_constraint_name = ccu.constraint_name
                AND rc.unique_constraint_schema = ccu.constraint_schema
            WHERE tc.table_schema = '\(escapedSchema)'
                AND tc.constraint_type = 'FOREIGN KEY'
            ORDER BY tc.table_name, tc.constraint_name
            """
        let result = try await execute(query: query)
        var grouped: [String: [PluginForeignKeyInfo]] = [:]
        for row in result.rows {
            guard row.count >= 8,
                  let tableName = row[0],
                  let name = row[1],
                  let column = row[2],
                  let refTable = row[3],
                  let refColumn = row[4]
            else { continue }
            let fk = PluginForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: refTable,
                referencedColumn: refColumn,
                referencedSchema: row[5],
                onDelete: row[6] ?? "NO ACTION",
                onUpdate: row[7] ?? "NO ACTION"
            )
            grouped[tableName, default: []].append(fk)
        }
        return grouped
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let query = """
            SELECT reltuples::bigint
            FROM pg_class
            WHERE relname = '\(escapeLiteral(table))'
              AND relnamespace = (
                  SELECT oid FROM pg_namespace WHERE nspname = current_schema()
              )
            """
        let result = try await execute(query: query)
        guard let firstRow = result.rows.first, let value = firstRow[0], let count = Int(value) else { return nil }
        return count >= 0 ? count : nil
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let safeTable = escapeLiteral(table)
        let quotedTable = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""

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

        let constraintsQuery = """
            SELECT
                pg_get_constraintdef(con.oid, true)
            FROM pg_constraint con
            JOIN pg_class c ON c.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = '\(safeTable)'
              AND n.nspname = '\(escapedSchema)'
              AND con.contype IN ('p', 'u', 'c', 'f')
            ORDER BY
              CASE con.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'c' THEN 2 WHEN 'f' THEN 3 END
            """

        let indexesQuery = """
            SELECT indexdef
            FROM pg_indexes
            WHERE tablename = '\(safeTable)'
              AND schemaname = '\(escapedSchema)'
              AND indexname NOT IN (
                SELECT conname FROM pg_constraint
                JOIN pg_class ON pg_class.oid = conrelid
                JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
                WHERE pg_class.relname = '\(safeTable)'
                  AND pg_namespace.nspname = '\(escapedSchema)'
              )
            ORDER BY indexname
            """

        async let columnsResult = execute(query: columnsQuery)
        async let constraintsResult = execute(query: constraintsQuery)
        async let indexesResult = execute(query: indexesQuery)

        let (cols, cons, idxs) = try await (columnsResult, constraintsResult, indexesResult)

        let columnDefs = cols.rows.compactMap { $0[0] }
        guard !columnDefs.isEmpty else {
            throw LibPQPluginError(message: "Failed to fetch DDL for table '\(table)'", sqlState: nil, detail: nil)
        }

        let constraints = cons.rows.compactMap { $0[0] }
        var parts = columnDefs
        parts.append(contentsOf: constraints)

        let quotedSchema = "\"\(_currentSchema.replacingOccurrences(of: "\"", with: "\"\""))\""
        let ddl = "CREATE TABLE \(quotedSchema).\(quotedTable) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n);"

        let indexDefs = idxs.rows.compactMap { $0[0] }
        if indexDefs.isEmpty { return ddl }
        return ddl + "\n\n" + indexDefs.joined(separator: ";\n") + ";"
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let query = """
            SELECT 'CREATE OR REPLACE VIEW ' || quote_ident(schemaname) || '.' || quote_ident(viewname) || ' AS ' || E'\\n' || definition AS ddl
            FROM pg_views
            WHERE viewname = '\(escapeLiteral(view))'
              AND schemaname = '\(escapedSchema)'
            """
        let result = try await execute(query: query)
        guard let firstRow = result.rows.first, let ddl = firstRow[0] else {
            throw LibPQPluginError(message: "Failed to fetch definition for view '\(view)'", sqlState: nil, detail: nil)
        }
        return ddl
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let query = """
            SELECT
                pg_total_relation_size(c.oid) AS total_size,
                pg_table_size(c.oid) AS data_size,
                pg_indexes_size(c.oid) AS index_size,
                c.reltuples::bigint AS row_count,
                obj_description(c.oid, 'pg_class') AS comment
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = '\(escapeLiteral(table))'
              AND n.nspname = '\(escapedSchema)'
            """
        let result = try await execute(query: query)
        guard let row = result.rows.first else {
            return PluginTableMetadata(tableName: table)
        }

        let totalSize = !row.isEmpty ? Int64(row[0] ?? "0") : nil
        let dataSize = row.count > 1 ? Int64(row[1] ?? "0") : nil
        let indexSize = row.count > 2 ? Int64(row[2] ?? "0") : nil
        let rowCount = row.count > 3 ? Int64(row[3] ?? "0") : nil
        let comment = row.count > 4 ? row[4] : nil

        return PluginTableMetadata(
            tableName: table,
            dataSize: dataSize,
            indexSize: indexSize,
            totalSize: totalSize,
            rowCount: rowCount,
            comment: comment?.isEmpty == true ? nil : comment,
            engine: "PostgreSQL"
        )
    }

    func fetchDatabases() async throws -> [String] {
        let result = try await execute(query: "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname")
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
        let query = """
            SELECT
                (SELECT COUNT(*)
                 FROM information_schema.tables
                 WHERE table_schema = 'public' AND table_catalog = '\(escapedDbLiteral)'),
                pg_database_size('\(escapedDbLiteral)')
        """
        let result = try await execute(query: query)
        let row = result.rows.first
        let tableCount = Int(row?[0] ?? "0") ?? 0
        let sizeBytes = Int64(row?[1] ?? "0") ?? 0

        let systemDatabases = ["postgres", "template0", "template1"]
        let isSystem = systemDatabases.contains(database)

        return PluginDatabaseMetadata(
            name: database,
            tableCount: tableCount,
            sizeBytes: sizeBytes,
            isSystemDatabase: isSystem
        )
    }

    func fetchAllDatabaseMetadata() async throws -> [PluginDatabaseMetadata] {
        let systemDatabases = ["postgres", "template0", "template1"]
        let query = """
            SELECT d.datname, pg_database_size(d.datname)
            FROM pg_database d
            WHERE d.datistemplate = false
            ORDER BY d.datname
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard let dbName = row[0] else { return nil }
            let sizeBytes = Int64(row[1] ?? "0") ?? 0
            let isSystem = systemDatabases.contains(dbName)
            return PluginDatabaseMetadata(name: dbName, sizeBytes: sizeBytes, isSystemDatabase: isSystem)
        }
    }

    func fetchDependentTypes(table: String, schema: String?) async throws -> [(name: String, labels: [String])] {
        let safeTable = escapeLiteral(table)
        let query = """
            SELECT DISTINCT t.typname,
                   array_agg(e.enumlabel ORDER BY e.enumsortorder)
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_type t ON t.oid = a.atttypid
            JOIN pg_enum e ON e.enumtypid = t.oid
            WHERE c.relname = '\(safeTable)'
              AND n.nspname = '\(escapedSchema)'
              AND a.attnum > 0
              AND NOT a.attisdropped
            GROUP BY t.typname
            ORDER BY t.typname
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard let typeName = row[0], let labelsStr = row[1] else { return nil }
            let labels = labelsStr
                .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                .components(separatedBy: ",")
            return (name: typeName, labels: labels)
        }
    }

    func fetchDependentSequences(table: String, schema: String?) async throws -> [(name: String, ddl: String)] {
        let safeTable = escapeLiteral(table)
        let query = """
            SELECT s.sequencename,
                   s.start_value,
                   s.min_value,
                   s.max_value,
                   s.increment_by,
                   s.cycle
            FROM pg_attrdef ad
            JOIN pg_class c ON c.oid = ad.adrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_sequences s ON s.schemaname = n.nspname
                 AND pg_get_expr(ad.adbin, ad.adrelid) LIKE '%' || quote_ident(s.sequencename) || '%'
            WHERE c.relname = '\(safeTable)'
              AND n.nspname = '\(escapedSchema)'
              AND pg_get_expr(ad.adbin, ad.adrelid) LIKE '%nextval%'
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard let seqName = row[0] else { return nil }
            let startVal = row[1] ?? "1"
            let minVal = row[2] ?? "1"
            let maxVal = row[3] ?? "9223372036854775807"
            let incrementBy = row[4] ?? "1"
            let cycle = row[5] == "t" ? " CYCLE" : ""
            let quotedSeqName = "\"\(seqName.replacingOccurrences(of: "\"", with: "\"\""))\""
            let ddl = "CREATE SEQUENCE \(quotedSeqName) INCREMENT BY \(incrementBy)"
                + " MINVALUE \(minVal) MAXVALUE \(maxVal)"
                + " START WITH \(startVal)\(cycle);"
            return (name: seqName, ddl: ddl)
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
            let allowedCollationChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
            let isValidCollation = collation.unicodeScalars.allSatisfy { allowedCollationChars.contains($0) }
            guard isValidCollation else {
                throw LibPQPluginError(message: "Invalid collation", sqlState: nil, detail: nil)
            }
            let escapedCollation = collation.replacingOccurrences(of: "'", with: "''")
            query += " LC_COLLATE '\(escapedCollation)'"
        }
        _ = try await execute(query: query)
    }

    func dropDatabase(name: String) async throws {
        let escapedName = name.replacingOccurrences(of: "\"", with: "\"\"")
        _ = try await execute(query: "DROP DATABASE \"\(escapedName)\"")
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        let s = schema ?? currentSchema ?? "public"
        return """
        SELECT
            schemaname as schema,
            relname as name,
            'TABLE' as kind,
            n_live_tup as estimated_rows,
            pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) as total_size,
            pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) as data_size,
            pg_size_pretty(pg_indexes_size(schemaname||'.'||relname)) as index_size,
            obj_description((schemaname||'.'||relname)::regclass) as comment
        FROM pg_stat_user_tables
        WHERE schemaname = '\(s)'
        ORDER BY relname
        """
    }

    // MARK: - Create Table DDL

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard !definition.columns.isEmpty else { return nil }

        let schema = _currentSchema
        let qualifiedTable = "\(quoteIdentifier(schema)).\(quoteIdentifier(definition.tableName))"
        let pkColumns = definition.columns.filter { $0.isPrimaryKey }
        let inlinePK = pkColumns.count == 1
        var parts: [String] = definition.columns.map { pgColumnDefinition($0, inlinePK: inlinePK) }

        if pkColumns.count > 1 {
            let pkCols = pkColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
            parts.append("PRIMARY KEY (\(pkCols))")
        }

        for fk in definition.foreignKeys {
            parts.append(pgForeignKeyDefinition(fk))
        }

        var sql = "CREATE TABLE \(qualifiedTable) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n);"

        var indexStatements: [String] = []
        for index in definition.indexes {
            indexStatements.append(pgIndexDefinition(index, qualifiedTable: qualifiedTable))
        }
        if !indexStatements.isEmpty {
            sql += "\n\n" + indexStatements.joined(separator: ";\n") + ";"
        }

        return sql
    }

    private func pgColumnDefinition(_ col: PluginColumnDefinition, inlinePK: Bool) -> String {
        var dataType = col.dataType
        if col.autoIncrement {
            let upper = dataType.uppercased()
            if upper == "BIGINT" || upper == "INT8" {
                dataType = "BIGSERIAL"
            } else {
                dataType = "SERIAL"
            }
        }

        var def = "\(quoteIdentifier(col.name)) \(dataType)"
        if !col.autoIncrement {
            if col.isNullable {
                def += " NULL"
            } else {
                def += " NOT NULL"
            }
        }
        if let defaultValue = col.defaultValue {
            def += " DEFAULT \(pgDefaultValue(defaultValue))"
        }
        if inlinePK && col.isPrimaryKey {
            def += " PRIMARY KEY"
        }
        return def
    }

    private func pgDefaultValue(_ value: String) -> String {
        let upper = value.uppercased()
        if upper == "NULL" || upper == "TRUE" || upper == "FALSE"
            || upper == "CURRENT_TIMESTAMP" || upper == "NOW()"
            || value.hasPrefix("'") || Int64(value) != nil || Double(value) != nil
            || upper.hasSuffix("::REGCLASS") {
            return value
        }
        return "'\(escapeLiteral(value))'"
    }

    private func pgIndexDefinition(_ index: PluginIndexDefinition, qualifiedTable: String) -> String {
        let cols = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let unique = index.isUnique ? "UNIQUE " : ""
        var def = "CREATE \(unique)INDEX \(quoteIdentifier(index.name)) ON \(qualifiedTable)"
        if let type = index.indexType?.uppercased(),
           ["BTREE", "HASH", "GIN", "GIST", "BRIN"].contains(type) {
            def += " USING \(type.lowercased())"
        }
        def += " (\(cols))"
        if let whereClause = index.whereClause, !whereClause.isEmpty {
            def += " WHERE \(whereClause)"
        }
        return def
    }

    private func pgForeignKeyDefinition(_ fk: PluginForeignKeyDefinition) -> String {
        let cols = fk.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let refCols = fk.referencedColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let refTable: String
        if let schema = fk.referencedSchema, !schema.isEmpty {
            refTable = "\(quoteIdentifier(schema)).\(quoteIdentifier(fk.referencedTable))"
        } else {
            refTable = quoteIdentifier(fk.referencedTable)
        }
        var def = "CONSTRAINT \(quoteIdentifier(fk.name)) FOREIGN KEY (\(cols)) REFERENCES \(refTable) (\(refCols))"
        if fk.onDelete != "NO ACTION" {
            def += " ON DELETE \(fk.onDelete)"
        }
        if fk.onUpdate != "NO ACTION" {
            def += " ON UPDATE \(fk.onUpdate)"
        }
        return def
    }

    // MARK: - Definition SQL (clipboard copy)

    func generateColumnDefinitionSQL(column: PluginColumnDefinition) -> String? {
        pgColumnDefinition(column, inlinePK: false)
    }

    func generateIndexDefinitionSQL(index: PluginIndexDefinition, tableName: String?) -> String? {
        let qualifiedTable = tableName.map { quoteIdentifier($0) } ?? "\"table\""
        return pgIndexDefinition(index, qualifiedTable: qualifiedTable)
    }

    func generateForeignKeyDefinitionSQL(fk: PluginForeignKeyDefinition) -> String? {
        pgForeignKeyDefinition(fk)
    }

    // MARK: - ALTER TABLE DDL

    private func qualifiedTableName(_ table: String) -> String {
        "\(quoteIdentifier(_currentSchema)).\(quoteIdentifier(table))"
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        let qt = qualifiedTableName(table)
        let colDef = pgColumnDefinition(column, inlinePK: false)
        return "ALTER TABLE \(qt) ADD COLUMN \(colDef)"
    }

    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? {
        let qt = qualifiedTableName(table)
        var stmts: [String] = []

        if oldColumn.name != newColumn.name {
            stmts.append("ALTER TABLE \(qt) RENAME COLUMN \(quoteIdentifier(oldColumn.name)) TO \(quoteIdentifier(newColumn.name))")
        }

        let colName = quoteIdentifier(newColumn.name)

        if oldColumn.dataType.uppercased() != newColumn.dataType.uppercased() {
            stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) TYPE \(newColumn.dataType)")
        }

        if oldColumn.isNullable != newColumn.isNullable {
            let clause = newColumn.isNullable ? "DROP NOT NULL" : "SET NOT NULL"
            stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) \(clause)")
        }

        if oldColumn.defaultValue != newColumn.defaultValue {
            if let defaultValue = newColumn.defaultValue {
                stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) SET DEFAULT \(pgDefaultValue(defaultValue))")
            } else {
                stmts.append("ALTER TABLE \(qt) ALTER COLUMN \(colName) DROP DEFAULT")
            }
        }

        if let newComment = newColumn.comment, !newComment.isEmpty, newColumn.comment != oldColumn.comment {
            stmts.append("COMMENT ON COLUMN \(qt).\(colName) IS '\(escapeLiteral(newComment))'")
        } else if oldColumn.comment != nil && (newColumn.comment == nil || newColumn.comment?.isEmpty == true) {
            stmts.append("COMMENT ON COLUMN \(qt).\(colName) IS NULL")
        }

        return stmts.isEmpty ? nil : stmts.joined(separator: ";\n")
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(qualifiedTableName(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        pgIndexDefinition(index, qualifiedTable: qualifiedTableName(table))
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "DROP INDEX \(quoteIdentifier(_currentSchema)).\(quoteIdentifier(indexName))"
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        "ALTER TABLE \(qualifiedTableName(table)) ADD \(pgForeignKeyDefinition(fk))"
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        "ALTER TABLE \(qualifiedTableName(table)) DROP CONSTRAINT \(quoteIdentifier(constraintName))"
    }

    func generateModifyPrimaryKeySQL(table: String, oldColumns: [String], newColumns: [String], constraintName: String?) -> [String]? {
        let qt = qualifiedTableName(table)
        var stmts: [String] = []
        if !oldColumns.isEmpty {
            let name = constraintName.map { quoteIdentifier($0) } ?? "/* unknown constraint */"
            stmts.append("ALTER TABLE \(qt) DROP CONSTRAINT \(name)")
        }
        if !newColumns.isEmpty {
            let cols = newColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
            stmts.append("ALTER TABLE \(qt) ADD PRIMARY KEY (\(cols))")
        }
        return stmts.isEmpty ? nil : stmts
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
