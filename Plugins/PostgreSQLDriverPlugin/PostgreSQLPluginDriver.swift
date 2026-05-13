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

    var currentSchema: String? { _currentSchema }
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }
    var serverVersion: String? { libpqConnection?.serverVersion() }
    var serverVersionNumber: Int32 { libpqConnection?.serverVersionNumber() ?? 0 }
    var capabilities: PostgreSQLCapabilities {
        PostgreSQLCapabilities(serverVersion: serverVersionNumber)
    }
    var parameterStyle: ParameterStyle { .dollar }

    var capabilities: PluginCapabilities {
        [
            .parameterizedQueries,
            .transactions,
            .alterTableDDL,
            .multiSchema,
            .cancelQuery,
            .batchExecute,
            .materializedViews,
            .foreignTables,
            .storedProcedures,
            .userFunctions
        ]
    }

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
           let schema = schemaResult.rows.first?.first?.asText {
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

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
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
        return pqConn.streamQuery(query)
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

    // MARK: - Foreign Keys

    func foreignKeyDisableStatements() -> [String]? {
        ["SET session_replication_role = replica"]
    }

    func foreignKeyEnableStatements() -> [String]? {
        ["SET session_replication_role = DEFAULT"]
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
        let schemaLiteral = escapeLiteral(schema ?? _currentSchema)
        let caps = capabilities

        var unions: [String] = [
            """
            SELECT table_name, table_type FROM information_schema.tables
            WHERE table_schema = '\(schemaLiteral)'
              AND table_type IN ('BASE TABLE', 'VIEW')
            """
        ]

        if caps.hasMaterializedViewsCatalog {
            unions.append(
                """
                SELECT matviewname AS table_name, 'MATERIALIZED VIEW' AS table_type
                FROM pg_matviews
                WHERE schemaname = '\(schemaLiteral)'
                """
            )
        }

        if caps.hasForeignTablesCatalog {
            unions.append(
                """
                SELECT c.relname AS table_name, 'FOREIGN TABLE' AS table_type
                FROM pg_foreign_table ft
                JOIN pg_class c ON c.oid = ft.ftrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = '\(schemaLiteral)'
                """
            )
        }

        let query = unions.joined(separator: "\nUNION ALL\n") + "\nORDER BY table_name"
        let result = try await execute(query: query)
        return result.rows.compactMap { row -> PluginTableInfo? in
            guard let name = row[0].asText else { return nil }
            let typeStr = row[1].asText ?? "BASE TABLE"
            let type: String
            switch typeStr {
            case "MATERIALIZED VIEW": type = "MATERIALIZED VIEW"
            case "FOREIGN TABLE":     type = "FOREIGN TABLE"
            case "VIEW":              type = "VIEW"
            default:                  type = "TABLE"
            }
            return PluginTableInfo(name: name, type: type)
        }
    }


    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let columnOrdering = capabilities.hasArrayPosition
            ? "ORDER BY array_position(ix.indkey, a.attnum)"
            : "ORDER BY a.attnum"
        let query = """
            SELECT
                i.relname AS index_name,
                ARRAY_AGG(a.attname \(columnOrdering)) AS columns,
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
        return result.rows.compactMap { row -> PluginIndexInfo? in
            guard row.count >= 5, let name = row[0].asText, let columnsStr = row[1].asText else { return nil }
            let columns = columnsStr
                .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                .components(separatedBy: ",")
            let whereClause = row.count > 5 ? row[5].asText : nil
            return PluginIndexInfo(
                name: name,
                columns: columns,
                isUnique: row[2].asText == "t",
                isPrimary: row[3].asText == "t",
                type: row[4].asText?.uppercased() ?? "BTREE",
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
        return result.rows.compactMap { row -> PluginForeignKeyInfo? in
            guard row.count >= 7,
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
                referencedSchema: row[4].asText,
                onDelete: row[5].asText ?? "NO ACTION",
                onUpdate: row[6].asText ?? "NO ACTION"
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
                  let tableName = row[0].asText,
                  let name = row[1].asText,
                  let column = row[2].asText,
                  let refTable = row[3].asText,
                  let refColumn = row[4].asText
            else { continue }
            let fk = PluginForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: refTable,
                referencedColumn: refColumn,
                referencedSchema: row[5].asText,
                onDelete: row[6].asText ?? "NO ACTION",
                onUpdate: row[7].asText ?? "NO ACTION"
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
        guard let firstRow = result.rows.first, let value = firstRow[0].asText, let count = Int(value) else { return nil }
        return count >= 0 ? count : nil
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let safeTable = escapeLiteral(table)
        let quotedTable = "\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\""
        let caps = capabilities

        let identityClause: String = caps.hasIdentityColumns ? """
                CASE
                  WHEN a.attidentity = 'a' THEN ' GENERATED ALWAYS AS IDENTITY'
                  WHEN a.attidentity = 'd' THEN ' GENERATED BY DEFAULT AS IDENTITY'
                  ELSE ''
                END ||
            """ : ""

        let generatedClause: String = caps.hasGeneratedColumns ? """
                CASE
                  WHEN a.attgenerated = 's' THEN ' GENERATED ALWAYS AS (' || pg_get_expr(d.adbin, d.adrelid) || ') STORED'
                  ELSE ''
                END ||
            """ : ""

        let defaultGuard: String
        switch (caps.hasIdentityColumns, caps.hasGeneratedColumns) {
        case (true, true):
            defaultGuard = "AND a.attidentity = '' AND a.attgenerated = ''"
        case (true, false):
            defaultGuard = "AND a.attidentity = ''"
        case (false, true):
            defaultGuard = "AND a.attgenerated = ''"
        case (false, false):
            defaultGuard = ""
        }

        let columnsQuery = """
            SELECT
                quote_ident(a.attname) || ' ' || format_type(a.atttypid, a.atttypmod) ||
                \(identityClause)
                \(generatedClause)
                CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END ||
                CASE
                  WHEN a.atthasdef \(defaultGuard)
                    THEN ' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid)
                  ELSE ''
                END
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
              AND con.contype IN ('p', 'u', 'c')
            ORDER BY
              CASE con.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'c' THEN 2 END
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

        let columnDefs = cols.rows.compactMap { $0[0].asText }
        guard !columnDefs.isEmpty else {
            throw LibPQPluginError(message: "Failed to fetch DDL for table '\(table)'", sqlState: nil, detail: nil)
        }

        let constraints = cons.rows.compactMap { $0[0].asText }
        var parts = columnDefs
        parts.append(contentsOf: constraints)

        let quotedSchema = "\"\(_currentSchema.replacingOccurrences(of: "\"", with: "\"\""))\""
        let ddl = "CREATE TABLE \(quotedSchema).\(quotedTable) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n);"

        let indexDefs = idxs.rows.compactMap { $0[0].asText }
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
        guard let firstRow = result.rows.first, let ddl = firstRow[0].asText else {
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

        let totalSize = !row.isEmpty ? Int64(row[0].asText ?? "0") : nil
        let dataSize = row.count > 1 ? Int64(row[1].asText ?? "0") : nil
        let indexSize = row.count > 2 ? Int64(row[2].asText ?? "0") : nil
        let rowCount = row.count > 3 ? Int64(row[3].asText ?? "0") : nil
        let comment = row.count > 4 ? row[4].asText : nil

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
        return result.rows.compactMap { row in row.first?.asText }
    }

    func fetchSchemas() async throws -> [String] {
        let result = try await execute(query: PostgreSQLSchemaQueries.listSchemas)
        return result.rows.compactMap { row in row.first?.asText }
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
        let tableCount = Int(row?[0].asText ?? "0") ?? 0
        let sizeBytes = Int64(row?[1].asText ?? "0") ?? 0

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
        return result.rows.compactMap { row -> PluginDatabaseMetadata? in
            guard let dbName = row[0].asText else { return nil }
            let sizeBytes = Int64(row[1].asText ?? "0") ?? 0
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
        return result.rows.compactMap { row -> (name: String, labels: [String])? in
            guard let typeName = row[0].asText, let labelsStr = row[1].asText else { return nil }
            let labels = labelsStr
                .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                .components(separatedBy: ",")
            return (name: typeName, labels: labels)
        }
    }

    func fetchDependentSequences(table: String, schema: String?) async throws -> [(name: String, ddl: String)] {
        guard capabilities.hasSequencesCatalog else { return [] }
        let safeTable = escapeLiteral(table)
        let query = """
            SELECT s.sequencename,
                   s.start_value,
                   s.min_value,
                   s.max_value,
                   s.increment_by,
                   s.cycle,
                   s.last_value
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
        let schemaName = schema ?? _currentSchema
        return result.rows.compactMap { row -> (name: String, ddl: String)? in
            guard let seqName = row[0].asText else { return nil }
            let startVal = row[1].asText ?? "1"
            let minVal = row[2].asText ?? "1"
            let maxVal = row[3].asText ?? "9223372036854775807"
            let incrementBy = row[4].asText ?? "1"
            let cycle = row[5].asText == "t" ? " CYCLE" : ""
            let lastValue = row.count > 6 ? row[6].asText : nil
            let quotedSeqName = "\"\(seqName.replacingOccurrences(of: "\"", with: "\"\""))\""
            let escapedSchemaForLiteral = schemaName.replacingOccurrences(of: "'", with: "''")
            let escapedSeqForLiteral = seqName.replacingOccurrences(of: "'", with: "''")
            var ddl = "CREATE SEQUENCE \(quotedSeqName) INCREMENT BY \(incrementBy)"
                + " MINVALUE \(minVal) MAXVALUE \(maxVal)"
                + " START WITH \(startVal)\(cycle);"
            if let last = lastValue, !last.isEmpty, Int64(last) != nil {
                ddl += "\nSELECT pg_catalog.setval('\"\(escapedSchemaForLiteral)\".\"\(escapedSeqForLiteral)\"', \(last), true);"
            }
            return (name: seqName, ddl: ddl)
        }
    }

    private static let supportedEncodings: [String] = [
        "UTF8", "LATIN1", "SQL_ASCII", "WIN1252", "EUC_JP",
        "EUC_KR", "ISO_8859_5", "KOI8R", "SJIS", "BIG5", "GBK"
    ]

    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? {
        let supportsProvider = capabilities.hasDatabaseICULocale

        async let templateDefaultsTask = fetchTemplate1Defaults()
        async let collationsTask = fetchCollations()
        let templateDefaults = await templateDefaultsTask
        let collations = await collationsTask
        let serverCollate = templateDefaults?.collate
        let serverIcuLocale = templateDefaults?.iculocale
        let libcCollations = collations.libc
        let icuCollations = collations.icu

        let encodingOptions = Self.supportedEncodings.map {
            PluginCreateDatabaseFormSpec.Option(value: $0, label: $0)
        }

        var fields: [PluginCreateDatabaseFormSpec.Field] = [
            PluginCreateDatabaseFormSpec.Field(
                id: "encoding",
                label: String(localized: "Encoding"),
                kind: .picker(options: encodingOptions, defaultValue: "UTF8")
            )
        ]

        if supportsProvider {
            let providerOptions: [PluginCreateDatabaseFormSpec.Option] = [
                PluginCreateDatabaseFormSpec.Option(value: "libc", label: "libc"),
                PluginCreateDatabaseFormSpec.Option(value: "icu", label: "icu")
            ]
            let defaultProvider = templateDefaults?.provider == "i" ? "icu" : "libc"
            fields.append(PluginCreateDatabaseFormSpec.Field(
                id: "provider",
                label: String(localized: "Locale Provider"),
                kind: .picker(options: providerOptions, defaultValue: defaultProvider)
            ))
        }

        let serverDefaultSubtitle = String(localized: "(server default)")
        let libcOptions: [PluginCreateDatabaseFormSpec.Option] = libcCollations.map { name in
            PluginCreateDatabaseFormSpec.Option(
                value: name,
                label: name,
                subtitle: name == serverCollate ? serverDefaultSubtitle : nil
            )
        }

        fields.append(PluginCreateDatabaseFormSpec.Field(
            id: "collation",
            label: String(localized: "Collation"),
            kind: .searchable(options: libcOptions, defaultValue: serverCollate),
            visibleWhen: supportsProvider
                ? PluginCreateDatabaseFormSpec.Visibility(fieldId: "provider", equals: "libc")
                : nil
        ))

        if supportsProvider {
            let icuOptions: [PluginCreateDatabaseFormSpec.Option] = icuCollations.map { name in
                PluginCreateDatabaseFormSpec.Option(
                    value: name,
                    label: name,
                    subtitle: name == serverIcuLocale ? serverDefaultSubtitle : nil
                )
            }
            fields.append(PluginCreateDatabaseFormSpec.Field(
                id: "icu_locale",
                label: String(localized: "ICU Locale"),
                kind: .searchable(options: icuOptions, defaultValue: serverIcuLocale),
                visibleWhen: PluginCreateDatabaseFormSpec.Visibility(fieldId: "provider", equals: "icu")
            ))
        }

        return PluginCreateDatabaseFormSpec(fields: fields)
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        let quotedName = request.name.replacingOccurrences(of: "\"", with: "\"\"")

        guard let encoding = request.values["encoding"] else {
            throw LibPQPluginError(
                message: String(localized: "Encoding is required"),
                sqlState: nil,
                detail: nil
            )
        }
        guard Self.supportedEncodings.contains(encoding) else {
            throw LibPQPluginError(
                message: String(format: String(localized: "Invalid encoding: %@"), encoding),
                sqlState: nil,
                detail: nil
            )
        }

        var sql = "CREATE DATABASE \"\(quotedName)\" ENCODING '\(encoding)'"

        let supportsProvider = capabilities.hasDatabaseICULocale
        let provider = supportsProvider ? (request.values["provider"] ?? "libc") : "libc"

        switch provider {
        case "libc":
            guard let collation = request.values["collation"], !collation.isEmpty else {
                throw LibPQPluginError(
                    message: String(localized: "Collation is required"),
                    sqlState: nil,
                    detail: nil
                )
            }
            async let allowedCollationsTask = fetchCollations().libc
            async let templateDefaultsTask = fetchTemplate1Defaults()
            let allowedCollations = await allowedCollationsTask
            guard allowedCollations.contains(collation) else {
                throw LibPQPluginError(
                    message: String(format: String(localized: "Invalid collation: %@"), collation),
                    sqlState: nil,
                    detail: nil
                )
            }
            let escapedCollation = escapeLiteral(collation)
            sql += " LC_COLLATE '\(escapedCollation)' LC_CTYPE '\(escapedCollation)'"

            guard let templateDefaults = await templateDefaultsTask else {
                throw LibPQPluginError(
                    message: String(localized: "Failed to read template1 collation defaults"),
                    sqlState: nil,
                    detail: nil
                )
            }
            if templateDefaults.collate != collation {
                sql += " TEMPLATE template0"
            }

        case "icu":
            guard supportsProvider else {
                throw LibPQPluginError(
                    message: String(localized: "ICU provider requires PostgreSQL 15 or newer"),
                    sqlState: nil,
                    detail: nil
                )
            }
            guard let icuLocale = request.values["icu_locale"], !icuLocale.isEmpty else {
                throw LibPQPluginError(
                    message: String(localized: "ICU locale is required"),
                    sqlState: nil,
                    detail: nil
                )
            }
            let allowedIcu = await fetchCollations().icu
            guard allowedIcu.contains(icuLocale) else {
                throw LibPQPluginError(
                    message: String(format: String(localized: "Invalid ICU locale: %@"), icuLocale),
                    sqlState: nil,
                    detail: nil
                )
            }
            let escapedIcu = escapeLiteral(icuLocale)
            if let major = majorVersion, major >= 16 {
                sql += " LOCALE_PROVIDER 'icu' LOCALE '\(escapedIcu)' TEMPLATE template0"
            } else {
                sql += " LOCALE_PROVIDER 'icu' ICU_LOCALE '\(escapedIcu)' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0"
            }

        default:
            throw LibPQPluginError(
                message: String(format: String(localized: "Invalid locale provider: %@"), provider),
                sqlState: nil,
                detail: nil
            )
        }

        _ = try await execute(query: sql)
    }

    func dropDatabase(name: String) async throws {
        let escapedName = name.replacingOccurrences(of: "\"", with: "\"\"")
        _ = try await execute(query: "DROP DATABASE \"\(escapedName)\"")
    }

    private struct Template1Defaults {
        let collate: String
        let ctype: String
        let provider: String?
        let iculocale: String?
    }

    private func fetchTemplate1Defaults() async -> Template1Defaults? {
        let caps = capabilities
        let selectColumns: String
        if caps.hasDatabaseLocale {
            selectColumns = "datcollate, datctype, datlocprovider, datlocale"
        } else if caps.hasDatabaseICULocale {
            selectColumns = "datcollate, datctype, datlocprovider, daticulocale"
        } else {
            selectColumns = "datcollate, datctype, NULL, NULL"
        }
        do {
            let result = try await execute(
                query: "SELECT \(selectColumns) FROM pg_database WHERE datname = 'template1'"
            )
            guard let row = result.rows.first,
                  row.count >= 4,
                  let collate = row[0].asText,
                  let ctype = row[1].asText else {
                return nil
            }
            return Template1Defaults(
                collate: collate,
                ctype: ctype,
                provider: row[2].asText,
                iculocale: row[3].asText
            )
        } catch {
            Self.logger.error(
                "Failed to read template1 defaults: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func fetchCollations() async -> (libc: [String], icu: [String]) {
        do {
            let result = try await execute(
                query: "SELECT collname, collprovider FROM pg_collation WHERE collprovider IN ('b', 'c', 'i') ORDER BY collname"
            )
            var libc: [String] = []
            var icu: [String] = []
            for row in result.rows {
                guard row.count >= 2, let name = row[0].asText, let provider = row[1].asText else { continue }
                switch provider {
                case "b", "c":
                    libc.append(name)
                case "i":
                    icu.append(name)
                default:
                    continue
                }
            }
            return (libc: libc, icu: icu)
        } catch {
            Self.logger.error(
                "Failed to read pg_collation: \(error.localizedDescription, privacy: .public)"
            )
            return (libc: [], icu: [])
        }
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
}
