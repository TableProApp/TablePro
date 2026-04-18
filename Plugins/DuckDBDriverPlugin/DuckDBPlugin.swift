//
//  DuckDBPlugin.swift
//  TablePro
//

import CDuckDB
import Foundation
import os
import TableProPluginKit

final class DuckDBPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "DuckDB Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "DuckDB analytical database support"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "DuckDB"
    static let databaseDisplayName = "DuckDB"
    static let iconName = "duckdb-icon"
    static let defaultPort = 0

    // MARK: - UI/Capability Metadata

    static let isDownloadable = true
    static let pathFieldRole: PathFieldRole = .filePath
    static let requiresAuthentication = false
    static let connectionMode: ConnectionMode = .fileBased
    static let urlSchemes: [String] = ["duckdb"]
    static let fileExtensions: [String] = ["duckdb", "ddb"]
    static let brandColorHex = "#FFD900"
    static let supportsDatabaseSwitching = false
    static let parameterStyle: ParameterStyle = .dollar
    static let systemDatabaseNames: [String] = ["information_schema", "pg_catalog"]
    static let databaseGroupingStrategy: GroupingStrategy = .flat
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT", "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT"],
        "Float": ["FLOAT", "DOUBLE", "DECIMAL", "NUMERIC"],
        "String": ["VARCHAR", "TEXT", "CHAR", "BPCHAR"],
        "Date": ["DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "TIMESTAMP_S", "TIMESTAMP_MS", "TIMESTAMP_NS", "INTERVAL"],
        "Binary": ["BLOB", "BYTEA", "BIT", "BITSTRING"],
        "Boolean": ["BOOLEAN"],
        "JSON": ["JSON"],
        "UUID": ["UUID"],
        "List": ["LIST"],
        "Struct": ["STRUCT"],
        "Map": ["MAP"],
        "Union": ["UNION"],
        "Enum": ["ENUM"]
    ]

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "\"",
        keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
            "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "ILIKE", "BETWEEN", "AS",
            "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "FETCH", "FIRST", "ROWS", "ONLY",
            "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
            "ADD", "MODIFY", "COLUMN", "RENAME",
            "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
            "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE", "NULLIF",
            "UNION", "INTERSECT", "EXCEPT",
            "COPY", "PRAGMA", "DESCRIBE", "SUMMARIZE", "PIVOT", "UNPIVOT",
            "QUALIFY", "SAMPLE", "TABLESAMPLE", "RETURNING",
            "INSTALL", "LOAD", "FORCE", "ATTACH", "DETACH",
            "EXPORT", "IMPORT",
            "WITH", "RECURSIVE", "MATERIALIZED",
            "EXPLAIN", "ANALYZE",
            "WINDOW", "OVER", "PARTITION"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN",
            "LIST_AGG", "STRING_AGG", "ARRAY_AGG",
            "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LENGTH", "LOWER", "UPPER",
            "TRIM", "LTRIM", "RTRIM", "REPLACE", "SPLIT_PART",
            "NOW", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
            "DATE_TRUNC", "EXTRACT", "AGE", "TO_CHAR", "TO_DATE",
            "EPOCH_MS",
            "ROUND", "CEIL", "CEILING", "FLOOR", "ABS", "MOD", "POW", "POWER", "SQRT",
            "CAST",
            "REGEXP_MATCHES", "READ_CSV", "READ_PARQUET", "READ_JSON",
            "GLOB", "STRUCT_PACK", "LIST_VALUE", "MAP", "UNNEST",
            "GENERATE_SERIES", "RANGE"
        ],
        dataTypes: [
            "INTEGER", "BIGINT", "HUGEINT", "UHUGEINT",
            "DOUBLE", "FLOAT", "DECIMAL",
            "VARCHAR", "TEXT", "BLOB",
            "BOOLEAN",
            "DATE", "TIME", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE", "INTERVAL",
            "UUID", "JSON",
            "LIST", "MAP", "STRUCT", "UNION", "ENUM", "BIT"
        ],
        regexSyntax: .regexpMatches,
        booleanLiteralStyle: .truefalse,
        likeEscapeStyle: .explicit,
        paginationStyle: .limit
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        DuckDBPluginDriver(config: config)
    }
}

// MARK: - DuckDB Connection Actor

private actor DuckDBConnectionActor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DuckDBConnectionActor")

    private var database: duckdb_database?
    private var connection: duckdb_connection?

    var isConnected: Bool { connection != nil }

    var connectionHandleForInterrupt: duckdb_connection? { connection }

    func open(path: String) throws {
        var db: duckdb_database?
        var errorPtr: UnsafeMutablePointer<CChar>?
        let state = duckdb_open_ext(path, &db, nil, &errorPtr)

        if state == DuckDBError {
            let detail: String
            if let errPtr = errorPtr {
                detail = String(cString: errPtr)
                duckdb_free(errPtr)
            } else {
                detail = "unknown error"
            }
            throw DuckDBPluginError.connectionFailed(
                "Failed to open DuckDB database at '\(path)': \(detail)"
            )
        }

        guard let openedDB = db else {
            throw DuckDBPluginError.connectionFailed(
                "Failed to open DuckDB database at '\(path)'"
            )
        }

        var conn: duckdb_connection?
        let connState = duckdb_connect(openedDB, &conn)

        if connState == DuckDBError {
            duckdb_close(&db)
            throw DuckDBPluginError.connectionFailed("Failed to create DuckDB connection")
        }

        database = db
        connection = conn
    }

    func close() {
        if connection != nil {
            duckdb_disconnect(&connection)
            connection = nil
        }
        if database != nil {
            duckdb_close(&database)
            database = nil
        }
    }

    func executeQuery(_ query: String) throws -> DuckDBRawResult {
        guard let conn = connection else {
            throw DuckDBPluginError.notConnected
        }

        let startTime = Date()
        var result = duckdb_result()

        let state = duckdb_query(conn, query, &result)

        if state == DuckDBError {
            let errorMsg: String
            if let errPtr = duckdb_result_error(&result) {
                errorMsg = String(cString: errPtr)
            } else {
                errorMsg = "Unknown DuckDB error"
            }
            duckdb_destroy_result(&result)
            throw DuckDBPluginError.queryFailed(errorMsg)
        }

        defer {
            duckdb_destroy_result(&result)
        }

        var raw = Self.extractResult(from: &result, startTime: startTime)
        Self.patchTzColumns(&raw, query: query, connection: conn)
        return raw
    }

    func executePrepared(_ query: String, parameters: [String?]) throws -> DuckDBRawResult {
        guard let conn = connection else {
            throw DuckDBPluginError.notConnected
        }

        let startTime = Date()
        var stmtOpt: duckdb_prepared_statement?

        let prepState = duckdb_prepare(conn, query, &stmtOpt)
        if prepState == DuckDBError {
            let errorMsg: String
            if let s = stmtOpt, let errPtr = duckdb_prepare_error(s) {
                errorMsg = String(cString: errPtr)
            } else {
                errorMsg = "Failed to prepare statement"
            }
            duckdb_destroy_prepare(&stmtOpt)
            throw DuckDBPluginError.queryFailed(errorMsg)
        }

        guard let stmt = stmtOpt else {
            throw DuckDBPluginError.queryFailed("Failed to prepare statement")
        }

        defer {
            duckdb_destroy_prepare(&stmtOpt)
        }

        for (index, param) in parameters.enumerated() {
            let paramIdx = idx_t(index + 1)
            if let value = param {
                let bindState = duckdb_bind_varchar(stmt, paramIdx, value)
                if bindState == DuckDBError {
                    throw DuckDBPluginError.queryFailed("Failed to bind parameter at index \(index)")
                }
            } else {
                let bindState = duckdb_bind_null(stmt, paramIdx)
                if bindState == DuckDBError {
                    throw DuckDBPluginError.queryFailed("Failed to bind NULL at index \(index)")
                }
            }
        }

        var result = duckdb_result()
        let execState = duckdb_execute_prepared(stmt, &result)

        if execState == DuckDBError {
            let errorMsg: String
            if let errPtr = duckdb_result_error(&result) {
                errorMsg = String(cString: errPtr)
            } else {
                errorMsg = "Failed to execute prepared statement"
            }
            duckdb_destroy_result(&result)
            throw DuckDBPluginError.queryFailed(errorMsg)
        }

        defer {
            duckdb_destroy_result(&result)
        }

        var raw = Self.extractResult(from: &result, startTime: startTime)
        Self.patchTzColumns(&raw, query: query, connection: conn)
        return raw
    }

    func streamQuery(
        _ query: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) throws {
        guard let conn = connection else {
            throw DuckDBPluginError.notConnected
        }

        var result = duckdb_result()
        let state = duckdb_query(conn, query, &result)

        if state == DuckDBError {
            let errorMsg: String
            if let errPtr = duckdb_result_error(&result) {
                errorMsg = String(cString: errPtr)
            } else {
                errorMsg = "Unknown DuckDB error"
            }
            duckdb_destroy_result(&result)
            throw DuckDBPluginError.queryFailed(errorMsg)
        }

        let colCount = duckdb_column_count(&result)
        let rowCount = duckdb_row_count(&result)

        var columns: [String] = []
        var columnTypeNames: [String] = []

        for i in 0..<colCount {
            if let namePtr = duckdb_column_name(&result, i) {
                columns.append(String(cString: namePtr))
            } else {
                columns.append("column_\(i)")
            }
            let colType = duckdb_column_type(&result, i)
            columnTypeNames.append(Self.typeName(for: colType))
        }

        continuation.yield(.header(PluginStreamHeader(
            columns: columns,
            columnTypeNames: columnTypeNames,
            estimatedRowCount: Int(rowCount)
        )))

        for row in 0..<rowCount {
            if Task.isCancelled {
                duckdb_destroy_result(&result)
                continuation.finish(throwing: CancellationError())
                return
            }

            var rowData: [String?] = []
            for col in 0..<colCount {
                if duckdb_value_is_null(&result, col, row) {
                    rowData.append(nil)
                } else if let valPtr = duckdb_value_varchar(&result, col, row) {
                    rowData.append(String(cString: valPtr))
                    duckdb_free(valPtr)
                } else {
                    let colType = duckdb_column_type(&result, col)
                    rowData.append(Self.extractFallbackValue(&result, col: col, row: row, type: colType))
                }
            }

            continuation.yield(.rows([rowData]))
        }

        duckdb_destroy_result(&result)
        continuation.finish()
    }

    private static func extractResult(
        from result: inout duckdb_result,
        startTime: Date
    ) -> DuckDBRawResult {
        let colCount = duckdb_column_count(&result)
        let rowCount = duckdb_row_count(&result)
        let rowsChanged = duckdb_rows_changed(&result)

        var columns: [String] = []
        var columnTypeNames: [String] = []
        var columnTypes: [duckdb_type] = []

        for i in 0..<colCount {
            if let namePtr = duckdb_column_name(&result, i) {
                columns.append(String(cString: namePtr))
            } else {
                columns.append("column_\(i)")
            }

            let colType = duckdb_column_type(&result, i)
            columnTypes.append(colType)
            columnTypeNames.append(Self.typeName(for: colType))
        }

        var rows: [[String?]] = []
        var truncated = false

        let maxRows = min(rowCount, UInt64(PluginRowLimits.defaultMax))
        if rowCount > UInt64(PluginRowLimits.defaultMax) {
            truncated = true
        }

        for row in 0..<maxRows {
            var rowData: [String?] = []

            for col in 0..<colCount {
                if duckdb_value_is_null(&result, col, row) {
                    rowData.append(nil)
                } else if let valPtr = duckdb_value_varchar(&result, col, row) {
                    rowData.append(String(cString: valPtr))
                    duckdb_free(valPtr)
                } else {
                    rowData.append(Self.extractFallbackValue(&result, col: col, row: row, type: columnTypes[Int(col)]))
                }
            }

            rows.append(rowData)
        }

        let executionTime = Date().timeIntervalSince(startTime)

        return DuckDBRawResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: Int(rowsChanged),
            executionTime: executionTime,
            isTruncated: truncated
        )
    }

    private static func typeName(for type: duckdb_type) -> String {
        switch type {
        case DUCKDB_TYPE_BOOLEAN: return "BOOLEAN"
        case DUCKDB_TYPE_TINYINT: return "TINYINT"
        case DUCKDB_TYPE_SMALLINT: return "SMALLINT"
        case DUCKDB_TYPE_INTEGER: return "INTEGER"
        case DUCKDB_TYPE_BIGINT: return "BIGINT"
        case DUCKDB_TYPE_UTINYINT: return "UTINYINT"
        case DUCKDB_TYPE_USMALLINT: return "USMALLINT"
        case DUCKDB_TYPE_UINTEGER: return "UINTEGER"
        case DUCKDB_TYPE_UBIGINT: return "UBIGINT"
        case DUCKDB_TYPE_FLOAT: return "FLOAT"
        case DUCKDB_TYPE_DOUBLE: return "DOUBLE"
        case DUCKDB_TYPE_TIMESTAMP: return "TIMESTAMP"
        case DUCKDB_TYPE_DATE: return "DATE"
        case DUCKDB_TYPE_TIME: return "TIME"
        case DUCKDB_TYPE_INTERVAL: return "INTERVAL"
        case DUCKDB_TYPE_HUGEINT: return "HUGEINT"
        case DUCKDB_TYPE_VARCHAR: return "VARCHAR"
        case DUCKDB_TYPE_BLOB: return "BLOB"
        case DUCKDB_TYPE_DECIMAL: return "DECIMAL"
        case DUCKDB_TYPE_TIMESTAMP_S: return "TIMESTAMP_S"
        case DUCKDB_TYPE_TIMESTAMP_MS: return "TIMESTAMP_MS"
        case DUCKDB_TYPE_TIMESTAMP_NS: return "TIMESTAMP_NS"
        case DUCKDB_TYPE_ENUM: return "ENUM"
        case DUCKDB_TYPE_LIST: return "LIST"
        case DUCKDB_TYPE_STRUCT: return "STRUCT"
        case DUCKDB_TYPE_MAP: return "MAP"
        case DUCKDB_TYPE_UUID: return "UUID"
        case DUCKDB_TYPE_UNION: return "UNION"
        case DUCKDB_TYPE_BIT: return "BIT"
        case DUCKDB_TYPE_TIMESTAMP_TZ: return "TIMESTAMPTZ"
        case DUCKDB_TYPE_TIME_TZ: return "TIMETZ"
        case DUCKDB_TYPE_TIME_NS: return "TIME_NS"
        case DUCKDB_TYPE_UHUGEINT: return "UHUGEINT"
        case DUCKDB_TYPE_ARRAY: return "ARRAY"
        default: return "VARCHAR"
        }
    }

    private static func extractFallbackValue(
        _ result: inout duckdb_result, col: idx_t, row: idx_t, type: duckdb_type
    ) -> String? {
        switch type {
        case DUCKDB_TYPE_TIMESTAMP, DUCKDB_TYPE_TIMESTAMP_S, DUCKDB_TYPE_TIMESTAMP_MS, DUCKDB_TYPE_TIMESTAMP_NS:
            let ts = duckdb_value_timestamp(&result, col, row)
            return formatTimestamp(ts)

        case DUCKDB_TYPE_DATE:
            let date = duckdb_value_date(&result, col, row)
            let d = duckdb_from_date(date)
            return String(format: "%04d-%02d-%02d", d.year, d.month, d.day)

        case DUCKDB_TYPE_TIME, DUCKDB_TYPE_TIME_NS:
            let time = duckdb_value_time(&result, col, row)
            return formatTime(duckdb_from_time(time))

        case DUCKDB_TYPE_BOOLEAN:
            return duckdb_value_boolean(&result, col, row) ? "true" : "false"

        case DUCKDB_TYPE_TINYINT:
            return String(duckdb_value_int8(&result, col, row))
        case DUCKDB_TYPE_SMALLINT:
            return String(duckdb_value_int16(&result, col, row))
        case DUCKDB_TYPE_INTEGER:
            return String(duckdb_value_int32(&result, col, row))
        case DUCKDB_TYPE_BIGINT:
            return String(duckdb_value_int64(&result, col, row))
        case DUCKDB_TYPE_UTINYINT:
            return String(duckdb_value_uint8(&result, col, row))
        case DUCKDB_TYPE_USMALLINT:
            return String(duckdb_value_uint16(&result, col, row))
        case DUCKDB_TYPE_UINTEGER:
            return String(duckdb_value_uint32(&result, col, row))
        case DUCKDB_TYPE_UBIGINT:
            return String(duckdb_value_uint64(&result, col, row))
        case DUCKDB_TYPE_FLOAT:
            return String(duckdb_value_float(&result, col, row))
        case DUCKDB_TYPE_DOUBLE:
            return String(duckdb_value_double(&result, col, row))

        case DUCKDB_TYPE_HUGEINT:
            let h = duckdb_value_hugeint(&result, col, row)
            return formatHugeInt(upper: h.upper, lower: h.lower)

        case DUCKDB_TYPE_UHUGEINT:
            let u = duckdb_value_uhugeint(&result, col, row)
            return formatUHugeInt(upper: u.upper, lower: u.lower)

        default:
            return nil
        }
    }

    /// DuckDB v1.5.0 C API: duckdb_value_varchar returns nil for TIMESTAMPTZ and TIMETZ,
    /// and duckdb_value_is_null is unreliable for these types. The only reliable method
    /// is re-executing the query with TZ columns cast to VARCHAR at the SQL level.
    private static func patchTzColumns(
        _ raw: inout DuckDBRawResult, query: String, connection: duckdb_connection
    ) {
        let tzTypes: Set<String> = ["TIMESTAMPTZ", "TIMETZ"]
        let tzColIndices = raw.columnTypeNames.enumerated().compactMap { idx, name in
            tzTypes.contains(name) ? idx : nil
        }
        guard !tzColIndices.isEmpty, !raw.rows.isEmpty else { return }

        var castExprs: [String] = []
        for (i, name) in raw.columns.enumerated() {
            let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
            if tzColIndices.contains(i) {
                castExprs.append(
                    "CASE WHEN \"\(escaped)\" IS NULL THEN NULL ELSE CAST(\"\(escaped)\" AS VARCHAR) END AS \"\(escaped)\""
                )
            } else {
                castExprs.append("\"\(escaped)\"")
            }
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix(";") ? String(query.dropLast()) : query
        let wrappedQuery = "SELECT \(castExprs.joined(separator: ", ")) FROM (\(trimmedQuery)) AS _tz_cast"
        var patchResult = duckdb_result()
        guard duckdb_query(connection, wrappedQuery, &patchResult) == DuckDBSuccess else { return }
        defer { duckdb_destroy_result(&patchResult) }

        let patchRowCount = min(duckdb_row_count(&patchResult), UInt64(raw.rows.count))
        for row in 0..<patchRowCount {
            for colIdx in tzColIndices {
                if duckdb_value_is_null(&patchResult, idx_t(colIdx), row) {
                    raw.rows[Int(row)][colIdx] = nil
                } else if let ptr = duckdb_value_varchar(&patchResult, idx_t(colIdx), row) {
                    raw.rows[Int(row)][colIdx] = String(cString: ptr)
                    duckdb_free(ptr)
                }
            }
        }
    }

    private static func formatTimestamp(_ ts: duckdb_timestamp) -> String {
        let parts = duckdb_from_timestamp(ts)
        let d = parts.date
        let t = parts.time
        let micros = t.micros % 1_000_000
        if micros == 0 {
            return String(
                format: "%04d-%02d-%02d %02d:%02d:%02d",
                d.year, d.month, d.day, t.hour, t.min, t.sec
            )
        }
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%06d",
            d.year, d.month, d.day, t.hour, t.min, t.sec, micros
        )
    }

    private static func formatTime(_ t: duckdb_time_struct) -> String {
        let micros = t.micros % 1_000_000
        if micros == 0 {
            return String(format: "%02d:%02d:%02d", t.hour, t.min, t.sec)
        }
        return String(format: "%02d:%02d:%02d.%06d", t.hour, t.min, t.sec, micros)
    }

    private static func formatHugeInt(upper: Int64, lower: UInt64) -> String {
        if upper == 0 {
            return String(lower)
        }
        if upper == -1, lower > Int64.max.magnitude {
            let val = ~upper
            let low = ~lower &+ 1
            return "-\(formatUHugeInt(upper: UInt64(val), lower: low))"
        }
        return formatUHugeInt(upper: UInt64(upper), lower: lower)
    }

    private static func formatUHugeInt(upper: UInt64, lower: UInt64) -> String {
        if upper == 0 {
            return String(lower)
        }
        let upperDecimal = Decimal(upper) * Decimal(sign: .plus, exponent: 0, significand: Decimal(UInt64.max) + 1)
        let result = upperDecimal + Decimal(lower)
        return "\(result)"
    }
}

private struct DuckDBRawResult: Sendable {
    let columns: [String]
    let columnTypeNames: [String]
    var rows: [[String?]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}

// MARK: - DuckDB Plugin Driver

final class DuckDBPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let connectionActor = DuckDBConnectionActor()
    private let stateLock = NSLock()
    nonisolated(unsafe) private var _connectionForInterrupt: duckdb_connection?
    nonisolated(unsafe) private var _currentSchema: String = "main"

    private static let logger = Logger(subsystem: "com.TablePro", category: "DuckDBPluginDriver")

    var currentSchema: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentSchema
    }
    var serverVersion: String? { String(cString: duckdb_library_version()) }
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }
    var parameterStyle: ParameterStyle { .dollar }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    private func resolveSchema(_ schema: String?) -> String {
        if let schema { return schema }
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentSchema
    }

    // MARK: - Connection

    func connect() async throws {
        let path = expandPath(config.database)

        if !FileManager.default.fileExists(atPath: path) {
            let directory = (path as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try? FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
            }
        }

        try await connectionActor.open(path: path)

        // Enable auto-install and auto-load of extensions (e.g. core_functions)
        do {
            try await connectionActor.executeQuery("SET autoinstall_known_extensions=1")
            try await connectionActor.executeQuery("SET autoload_known_extensions=1")
        } catch {
            Self.logger.warning("Failed to enable DuckDB extension autoloading: \(error.localizedDescription)")
        }

        if let conn = await connectionActor.connectionHandleForInterrupt {
            setInterruptHandle(conn)
        }
    }

    func disconnect() {
        stateLock.lock()
        _connectionForInterrupt = nil
        stateLock.unlock()
        let actor = connectionActor
        Task { await actor.close() }
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        // DuckDB doesn't have a session-level query timeout like network databases
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let rawResult = try await connectionActor.executeQuery(query)
        return PluginQueryResult(
            columns: rawResult.columns,
            columnTypeNames: rawResult.columnTypeNames,
            rows: rawResult.rows,
            rowsAffected: rawResult.rowsAffected,
            executionTime: rawResult.executionTime,
            isTruncated: rawResult.isTruncated
        )
    }

    func executeParameterized(
        query: String,
        parameters: [String?]
    ) async throws -> PluginQueryResult {
        let rawResult = try await connectionActor.executePrepared(query, parameters: parameters)
        return PluginQueryResult(
            columns: rawResult.columns,
            columnTypeNames: rawResult.columnTypeNames,
            rows: rawResult.rows,
            rowsAffected: rawResult.rowsAffected,
            executionTime: rawResult.executionTime,
            isTruncated: rawResult.isTruncated
        )
    }

    func cancelQuery() throws {
        stateLock.lock()
        let conn = _connectionForInterrupt
        stateLock.unlock()
        guard let conn else { return }
        duckdb_interrupt(conn)
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let baseQuery = stripLimitOffset(from: query)
        let actor = connectionActor

        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            Task {
                do {
                    try await actor.streamQuery(baseQuery, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Pagination

    func fetchRowCount(query: String) async throws -> Int {
        let baseQuery = stripLimitOffset(from: query)
        let countQuery = "SELECT COUNT(*) FROM (\(baseQuery)) AS _count_subquery"
        let result = try await execute(query: countQuery)
        guard let firstRow = result.rows.first, let countStr = firstRow.first else { return 0 }
        return Int(countStr ?? "0") ?? 0
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        let baseQuery = stripLimitOffset(from: query)
        let paginatedQuery = "\(baseQuery) LIMIT \(limit) OFFSET \(offset)"
        return try await execute(query: paginatedQuery)
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let schemaName = resolveSchema(schema)
        let query = """
            SELECT table_name, table_type
            FROM information_schema.tables
            WHERE table_schema = $1
            ORDER BY table_name
        """
        let result = try await executeParameterized(query: query, parameters: [schemaName])
        return result.rows.compactMap { row in
            guard let name = row[safe: 0] ?? nil else { return nil }
            let typeString = (row[safe: 1] ?? nil) ?? "BASE TABLE"
            let tableType = typeString.uppercased().contains("VIEW") ? "VIEW" : "TABLE"
            return PluginTableInfo(name: name, type: tableType)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let schemaName = resolveSchema(schema)
        let query = """
            SELECT column_name, data_type, is_nullable, column_default, ordinal_position
            FROM information_schema.columns
            WHERE table_schema = $1
              AND table_name = $2
            ORDER BY ordinal_position
        """
        let result = try await executeParameterized(query: query, parameters: [schemaName, table])

        let pkColumns = try await fetchPrimaryKeyColumns(table: table, schema: schemaName)

        return result.rows.compactMap { row in
            guard let name = row[safe: 0] ?? nil,
                  let dataType = row[safe: 1] ?? nil else {
                return nil
            }

            let isNullable = (row[safe: 2] ?? nil) == "YES"
            let defaultValue = row[safe: 3] ?? nil
            let isPrimaryKey = pkColumns.contains(name)

            return PluginColumnInfo(
                name: name,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue
            )
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let schemaName = resolveSchema(schema)
        let query = """
            SELECT table_name, column_name, data_type, is_nullable, column_default, ordinal_position
            FROM information_schema.columns
            WHERE table_schema = $1
            ORDER BY table_name, ordinal_position
        """
        let result = try await executeParameterized(query: query, parameters: [schemaName])

        let pkQuery = """
            SELECT tc.table_name, kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name
              AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'PRIMARY KEY'
              AND tc.table_schema = $1
        """
        let pkResult = try await executeParameterized(query: pkQuery, parameters: [schemaName])
        var pkMap: [String: Set<String>] = [:]
        for row in pkResult.rows {
            if let tableName = row[safe: 0] ?? nil, let colName = row[safe: 1] ?? nil {
                pkMap[tableName, default: []].insert(colName)
            }
        }

        var allColumns: [String: [PluginColumnInfo]] = [:]

        for row in result.rows {
            guard let tableName = row[safe: 0] ?? nil,
                  let columnName = row[safe: 1] ?? nil,
                  let dataType = row[safe: 2] ?? nil else {
                continue
            }

            let isNullable = (row[safe: 3] ?? nil) == "YES"
            let defaultValue = row[safe: 4] ?? nil
            let isPrimaryKey = pkMap[tableName]?.contains(columnName) ?? false

            let column = PluginColumnInfo(
                name: columnName,
                dataType: dataType,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                defaultValue: defaultValue
            )

            allColumns[tableName, default: []].append(column)
        }

        return allColumns
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let schemaName = resolveSchema(schema)
        let query = """
            SELECT index_name, is_unique, sql, index_oid
            FROM duckdb_indexes()
            WHERE schema_name = $1
              AND table_name = $2
        """

        do {
            let result = try await executeParameterized(
                query: query, parameters: [schemaName, table]
            )
            return result.rows.compactMap { row in
                guard let name = row[safe: 0] ?? nil else { return nil }
                let isUnique = (row[safe: 1] ?? nil) == "true"
                let sql = row[safe: 2] ?? nil
                let isPrimary = name.lowercased().contains("primary")
                    || (sql?.uppercased().contains("PRIMARY KEY") ?? false)

                let columns = extractIndexColumns(from: sql)

                return PluginIndexInfo(
                    name: name,
                    columns: columns,
                    isUnique: isUnique || isPrimary,
                    isPrimary: isPrimary,
                    type: "ART"
                )
            }.sorted { $0.isPrimary && !$1.isPrimary }
        } catch {
            return []
        }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        let schemaName = resolveSchema(schema)
        let query = """
            SELECT
                rc.constraint_name,
                kcu.column_name,
                kcu2.table_name AS referenced_table,
                kcu2.column_name AS referenced_column,
                rc.delete_rule,
                rc.update_rule
            FROM information_schema.referential_constraints rc
            JOIN information_schema.key_column_usage kcu
                ON rc.constraint_name = kcu.constraint_name
                AND rc.constraint_schema = kcu.constraint_schema
            JOIN information_schema.key_column_usage kcu2
                ON rc.unique_constraint_name = kcu2.constraint_name
                AND rc.unique_constraint_schema = kcu2.constraint_schema
                AND kcu.ordinal_position = kcu2.ordinal_position
            WHERE kcu.table_schema = $1
              AND kcu.table_name = $2
        """

        do {
            let result = try await executeParameterized(
                query: query, parameters: [schemaName, table]
            )
            return result.rows.compactMap { row in
                guard let name = row[safe: 0] ?? nil,
                      let column = row[safe: 1] ?? nil,
                      let refTable = row[safe: 2] ?? nil,
                      let refColumn = row[safe: 3] ?? nil else {
                    return nil
                }

                let onDelete = (row[safe: 4] ?? nil) ?? "NO ACTION"
                let onUpdate = (row[safe: 5] ?? nil) ?? "NO ACTION"

                return PluginForeignKeyInfo(
                    name: name,
                    column: column,
                    referencedTable: refTable,
                    referencedColumn: refColumn,
                    onDelete: onDelete,
                    onUpdate: onUpdate
                )
            }
        } catch {
            return []
        }
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let schemaName = resolveSchema(schema)

        // Try native DDL from duckdb_tables() first (preserves complex types like LIST, STRUCT, MAP)
        let nativeQuery = "SELECT sql FROM duckdb_tables() WHERE schema_name = $1 AND table_name = $2"
        let nativeResult = try await executeParameterized(query: nativeQuery, parameters: [schemaName, table])

        if let firstRow = nativeResult.rows.first, let sql = firstRow[0] {
            var ddl = sql.hasSuffix(";") ? sql : sql + ";"

            // Append index definitions
            let indexes = try await fetchIndexes(table: table, schema: schemaName)
            for index in indexes where !index.isPrimary {
                let uniqueStr = index.isUnique ? "UNIQUE " : ""
                let cols = index.columns.map { "\"\(escapeIdentifier($0))\"" }.joined(separator: ", ")
                ddl += "\n\nCREATE \(uniqueStr)INDEX \"\(escapeIdentifier(index.name))\""
                    + " ON \"\(escapeIdentifier(schemaName))\".\"\(escapeIdentifier(table))\""
                    + " (\(cols));"
            }

            return ddl
        }

        // Fallback: synthesize DDL from schema metadata
        let columns = try await fetchColumns(table: table, schema: schemaName)
        let indexes = try await fetchIndexes(table: table, schema: schemaName)
        let fks = try await fetchForeignKeys(table: table, schema: schemaName)

        var ddl = "CREATE TABLE \"\(escapeIdentifier(schemaName))\".\"\(escapeIdentifier(table))\" (\n"

        let columnDefs = columns.map { col in
            var def = "  \"\(escapeIdentifier(col.name))\" \(col.dataType)"
            if !col.isNullable { def += " NOT NULL" }
            if let defaultVal = col.defaultValue { def += " DEFAULT \(defaultVal)" }
            return def
        }

        var allDefs = columnDefs

        let pkColumns = columns.filter(\.isPrimaryKey)
        if !pkColumns.isEmpty {
            let pkCols = pkColumns.map { "\"\(escapeIdentifier($0.name))\"" }
                .joined(separator: ", ")
            allDefs.append("  PRIMARY KEY (\(pkCols))")
        }

        for fk in fks {
            let fkDef = "  FOREIGN KEY (\"\(escapeIdentifier(fk.column))\")"
                + " REFERENCES \"\(escapeIdentifier(fk.referencedTable))\""
                + "(\"\(escapeIdentifier(fk.referencedColumn))\")"
                + " ON DELETE \(fk.onDelete) ON UPDATE \(fk.onUpdate)"
            allDefs.append(fkDef)
        }

        ddl += allDefs.joined(separator: ",\n")
        ddl += "\n);"

        for index in indexes where !index.isPrimary {
            let uniqueStr = index.isUnique ? "UNIQUE " : ""
            let cols = index.columns.map { "\"\(escapeIdentifier($0))\"" }.joined(separator: ", ")
            ddl += "\n\nCREATE \(uniqueStr)INDEX \"\(escapeIdentifier(index.name))\""
                + " ON \"\(escapeIdentifier(schemaName))\".\"\(escapeIdentifier(table))\""
                + " (\(cols));"
        }

        return ddl
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let schemaName = resolveSchema(schema)
        let query = """
            SELECT view_definition
            FROM information_schema.views
            WHERE table_schema = $1
              AND table_name = $2
        """
        let result = try await executeParameterized(query: query, parameters: [schemaName, view])

        guard let firstRow = result.rows.first,
              let definition = firstRow[0] else {
            throw DuckDBPluginError.queryFailed(
                "Failed to fetch definition for view '\(view)'"
            )
        }

        return "CREATE VIEW \"\(escapeIdentifier(schemaName))\".\"\(escapeIdentifier(view))\" AS\n\(definition)"
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let schemaName = resolveSchema(schema)
        let safeTable = escapeIdentifier(table)
        let safeSchema = escapeIdentifier(schemaName)
        let countQuery =
            "SELECT COUNT(*) FROM (SELECT 1 FROM \"\(safeSchema)\".\"\(safeTable)\" LIMIT 100001) AS _t"
        let countResult = try await execute(query: countQuery)
        let rowCount: Int64? = {
            guard let row = countResult.rows.first, let countStr = row.first else { return nil }
            return Int64(countStr ?? "0")
        }()

        return PluginTableMetadata(
            tableName: table,
            rowCount: rowCount,
            engine: "DuckDB"
        )
    }

    // MARK: - Schema Navigation

    func fetchSchemas() async throws -> [String] {
        let query = "SELECT schema_name FROM information_schema.schemata ORDER BY schema_name"
        let result = try await execute(query: query)
        return result.rows.compactMap { $0[safe: 0] ?? nil }
    }

    func switchSchema(to schema: String) async throws {
        let safeSchema = escapeIdentifier(schema)
        _ = try await execute(query: "SET schema = \"\(safeSchema)\"")
        stateLock.lock()
        _currentSchema = schema
        stateLock.unlock()
    }

    // MARK: - Database Operations

    func fetchDatabases() async throws -> [String] {
        let query = "SELECT database_name FROM duckdb_databases() ORDER BY database_name"
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            row[safe: 0] ?? nil
        }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        throw DuckDBPluginError.unsupportedOperation
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN \(sql)"
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "CREATE OR REPLACE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let quoted = quoteIdentifier(viewName)
        return "CREATE OR REPLACE VIEW \(quoted) AS\nSELECT * FROM table_name;"
    }

    // MARK: - All Tables Metadata

    func allTablesMetadataSQL(schema: String?) -> String? {
        let s = schema ?? currentSchema ?? "main"
        return """
        SELECT
            table_schema as schema_name,
            table_name as name,
            table_type as kind
        FROM information_schema.tables
        WHERE table_schema = '\(s)'
        ORDER BY table_name
        """
    }

    // MARK: - Private Helpers

    nonisolated private func setInterruptHandle(_ handle: duckdb_connection?) {
        stateLock.lock()
        _connectionForInterrupt = handle
        stateLock.unlock()
    }

    private func expandPath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return NSString(string: path).expandingTildeInPath
        }
        return path
    }

    private func escapeIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\"\"")
    }

    private func stripLimitOffset(from query: String) -> String {
        var result = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip trailing semicolons
        while result.hasSuffix(";") {
            result = String(result.dropLast()).trimmingCharacters(in: .whitespaces)
        }

        // Only strip LIMIT/OFFSET at the top level (depth 0) from the end.
        // Strip OFFSET first (comes after LIMIT), then LIMIT.
        for keyword in ["OFFSET", "LIMIT"] {
            let upper = result.uppercased() as NSString
            if let pos = findLastTopLevelKeyword(keyword, upper: upper, length: upper.length) {
                result = (result as NSString).substring(to: pos)
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        return result
    }

    private func findLastTopLevelKeyword(
        _ keyword: String,
        upper: NSString,
        length: Int
    ) -> Int? {
        let keyLen = keyword.count
        let parenOpen = UInt16(UnicodeScalar("(").value)
        let parenClose = UInt16(UnicodeScalar(")").value)
        let singleQuote = UInt16(UnicodeScalar("'").value)
        let doubleQuote = UInt16(UnicodeScalar("\"").value)

        var depth = 0
        var inString = false
        var inIdentifier = false
        var i = length - 1

        while i >= 0 {
            let ch = upper.character(at: i)

            if inString {
                if ch == singleQuote {
                    if i > 0 && upper.character(at: i - 1) == singleQuote {
                        i -= 1
                    } else {
                        inString = false
                    }
                }
            } else if inIdentifier {
                if ch == doubleQuote {
                    if i > 0 && upper.character(at: i - 1) == doubleQuote {
                        i -= 1
                    } else {
                        inIdentifier = false
                    }
                }
            } else {
                if ch == singleQuote {
                    inString = true
                } else if ch == doubleQuote {
                    inIdentifier = true
                } else if ch == parenClose {
                    depth += 1
                } else if ch == parenOpen {
                    depth -= 1
                } else if depth == 0 {
                    let start = i - keyLen + 1
                    if start >= 0 {
                        let candidate = upper.substring(with: NSRange(location: start, length: keyLen))
                        if candidate == keyword {
                            let beforeOk = start == 0 || {
                                guard let scalar = Unicode.Scalar(upper.character(at: start - 1)) else {
                                    return false
                                }
                                return CharacterSet.whitespaces.contains(scalar)
                            }()
                            if beforeOk {
                                return start
                            }
                        }
                    }
                }
            }
            i -= 1
        }

        return nil
    }

    private func fetchPrimaryKeyColumns(
        table: String,
        schema: String
    ) async throws -> Set<String> {
        let query = """
            SELECT kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name
              AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'PRIMARY KEY'
              AND tc.table_schema = $1
              AND tc.table_name = $2
        """
        let result = try await executeParameterized(query: query, parameters: [schema, table])
        return Set(result.rows.compactMap { $0[safe: 0] ?? nil })
    }

    // MARK: - Create Table DDL

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard !definition.columns.isEmpty else { return nil }

        let schema = _currentSchema
        let qualifiedTable = "\(quoteIdentifier(schema)).\(quoteIdentifier(definition.tableName))"
        let pkColumns = definition.columns.filter { $0.isPrimaryKey }
        let inlinePK = pkColumns.count == 1
        var parts: [String] = definition.columns.map { duckdbColumnDefinition($0, inlinePK: inlinePK) }

        if pkColumns.count > 1 {
            let pkCols = pkColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
            parts.append("PRIMARY KEY (\(pkCols))")
        }

        for fk in definition.foreignKeys {
            parts.append(duckdbForeignKeyDefinition(fk))
        }

        var sql = "CREATE TABLE \(qualifiedTable) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n);"

        var indexStatements: [String] = []
        for index in definition.indexes {
            indexStatements.append(duckdbIndexDefinition(index, qualifiedTable: qualifiedTable))
        }
        if !indexStatements.isEmpty {
            sql += "\n\n" + indexStatements.joined(separator: ";\n") + ";"
        }

        return sql
    }

    private func duckdbColumnDefinition(_ col: PluginColumnDefinition, inlinePK: Bool) -> String {
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
            def += " DEFAULT \(duckdbDefaultValue(defaultValue))"
        }
        if inlinePK && col.isPrimaryKey {
            def += " PRIMARY KEY"
        }
        return def
    }

    private func duckdbDefaultValue(_ value: String) -> String {
        let upper = value.uppercased()
        if upper == "NULL" || upper == "TRUE" || upper == "FALSE"
            || upper == "CURRENT_TIMESTAMP" || upper == "NOW()"
            || value.hasPrefix("'") || Int64(value) != nil || Double(value) != nil {
            return value
        }
        return "'\(escapeStringLiteral(value))'"
    }

    private func duckdbIndexDefinition(_ index: PluginIndexDefinition, qualifiedTable: String) -> String {
        let cols = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let unique = index.isUnique ? "UNIQUE " : ""
        return "CREATE \(unique)INDEX \(quoteIdentifier(index.name)) ON \(qualifiedTable) (\(cols))"
    }

    private func duckdbForeignKeyDefinition(_ fk: PluginForeignKeyDefinition) -> String {
        let cols = fk.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let refCols = fk.referencedColumns.map { quoteIdentifier($0) }.joined(separator: ", ")
        var def = "CONSTRAINT \(quoteIdentifier(fk.name)) FOREIGN KEY (\(cols)) REFERENCES \(quoteIdentifier(fk.referencedTable)) (\(refCols))"
        if fk.onDelete != "NO ACTION" {
            def += " ON DELETE \(fk.onDelete)"
        }
        if fk.onUpdate != "NO ACTION" {
            def += " ON UPDATE \(fk.onUpdate)"
        }
        return def
    }

    private static let indexColumnsRegex = try? NSRegularExpression(
        pattern: #"ON\s+(?:(?:"[^"]*"|[^\s(]+)\s*\.\s*)*(?:"[^"]*"|[^\s(]+)\s*\(([^)]+)\)"#,
        options: .caseInsensitive
    )

    private func extractIndexColumns(from sql: String?) -> [String] {
        guard let sql, let regex = Self.indexColumnsRegex else { return [] }

        let range = NSRange(sql.startIndex..., in: sql)
        guard let match = regex.firstMatch(in: sql, range: range),
              match.numberOfRanges > 1,
              let columnsRange = Range(match.range(at: 1), in: sql) else {
            return []
        }

        return String(sql[columnsRange]).split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")
        }
    }
}

// MARK: - Errors

enum DuckDBPluginError: Error {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case unsupportedOperation
}

extension DuckDBPluginError: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case .connectionFailed(let msg): return msg
        case .notConnected: return String(localized: "Not connected to database")
        case .queryFailed(let msg): return msg
        case .unsupportedOperation: return String(localized: "Operation not supported")
        }
    }
}
