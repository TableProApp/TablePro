//
//  DuckDBConnection.swift
//  DuckDBDriverPlugin
//

import CDuckDB
import Foundation
import os
import TableProPluginKit

actor DuckDBConnectionActor {
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
        Self.patchCastedColumns(&raw, query: query, connection: conn)
        return raw
    }

    func executePrepared(_ query: String, parameters: [PluginCellValue]) throws -> DuckDBRawResult {
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
            let bindState: duckdb_state
            switch param {
            case .null:
                bindState = duckdb_bind_null(stmt, paramIdx)
            case .text(let value):
                bindState = duckdb_bind_varchar(stmt, paramIdx, value)
            case .bytes(let data):
                bindState = data.withUnsafeBytes { rawBuffer -> duckdb_state in
                    guard let baseAddress = rawBuffer.baseAddress else {
                        return duckdb_bind_null(stmt, paramIdx)
                    }
                    return duckdb_bind_blob(stmt, paramIdx, baseAddress, idx_t(data.count))
                }
            }
            if bindState == DuckDBError {
                throw DuckDBPluginError.queryFailed("Failed to bind parameter at index \(index)")
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
        Self.patchCastedColumns(&raw, query: query, connection: conn)
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

        if columnTypes.contains(where: Self.requiresTextCast) {
            duckdb_destroy_result(&result)
            try Self.streamWrappedQuery(
                query: query,
                columns: columns,
                columnTypeNames: columnTypeNames,
                columnTypes: columnTypes,
                connection: conn,
                continuation: continuation
            )
            return
        }

        defer { duckdb_destroy_result(&result) }
        try Self.streamResultRows(
            &result,
            columns: columns,
            columnTypeNames: columnTypeNames,
            continuation: continuation
        )
    }

    private static func streamWrappedQuery(
        query: String,
        columns: [String],
        columnTypeNames: [String],
        columnTypes: [duckdb_type],
        connection: duckdb_connection,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) throws {
        let castExprs = columns.enumerated().map { i, name in
            projection(for: columnTypes[i], column: name)
        }
        let wrappedQuery = buildWrappedQuery(originalQuery: query, castExprs: castExprs)

        var result = duckdb_result()
        let state = duckdb_query(connection, wrappedQuery, &result)
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
        defer { duckdb_destroy_result(&result) }

        try Self.streamResultRows(
            &result,
            columns: columns,
            columnTypeNames: columnTypeNames,
            continuation: continuation
        )
    }

    private static func streamResultRows(
        _ result: inout duckdb_result,
        columns: [String],
        columnTypeNames: [String],
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) throws {
        let colCount = duckdb_column_count(&result)
        let rowCount = duckdb_row_count(&result)

        continuation.yield(.header(PluginStreamHeader(
            columns: columns,
            columnTypeNames: columnTypeNames,
            estimatedRowCount: Int(rowCount)
        )))

        let maxRows = min(rowCount, UInt64(PluginRowLimits.emergencyMax))
        if rowCount > UInt64(PluginRowLimits.emergencyMax) {
            Self.logger.warning("streamQuery truncating result from \(rowCount) to \(maxRows) rows")
        }

        for row in 0..<maxRows {
            if Task.isCancelled {
                continuation.finish(throwing: CancellationError())
                return
            }

            var rowData: [PluginCellValue] = []
            for col in 0..<colCount {
                let colType = duckdb_column_type(&result, col)
                if duckdb_value_is_null(&result, col, row) {
                    rowData.append(.null)
                } else if colType == DUCKDB_TYPE_BLOB {
                    let blob = duckdb_value_blob(&result, col, row)
                    if let ptr = blob.data {
                        rowData.append(.bytes(Data(bytes: ptr, count: Int(blob.size))))
                    } else {
                        rowData.append(.bytes(Data()))
                    }
                    duckdb_free(blob.data)
                } else if let valPtr = duckdb_value_varchar(&result, col, row) {
                    rowData.append(.text(String(cString: valPtr)))
                    duckdb_free(valPtr)
                } else {
                    rowData.append(PluginCellValue.fromOptional(
                        Self.extractFallbackValue(&result, col: col, row: row, type: colType)
                    ))
                }
            }

            continuation.yield(.rows([rowData]))
        }

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

        var rows: [[PluginCellValue]] = []
        var truncated = false

        let maxRows = min(rowCount, UInt64(PluginRowLimits.emergencyMax))
        if rowCount > UInt64(PluginRowLimits.emergencyMax) {
            truncated = true
        }

        for row in 0..<maxRows {
            var rowData: [PluginCellValue] = []

            for col in 0..<colCount {
                let colType = columnTypes[Int(col)]
                if duckdb_value_is_null(&result, col, row) {
                    rowData.append(.null)
                } else if colType == DUCKDB_TYPE_BLOB {
                    let blob = duckdb_value_blob(&result, col, row)
                    if let ptr = blob.data {
                        rowData.append(.bytes(Data(bytes: ptr, count: Int(blob.size))))
                    } else {
                        rowData.append(.bytes(Data()))
                    }
                    duckdb_free(blob.data)
                } else if let valPtr = duckdb_value_varchar(&result, col, row) {
                    rowData.append(.text(String(cString: valPtr)))
                    duckdb_free(valPtr)
                } else {
                    rowData.append(PluginCellValue.fromOptional(
                        Self.extractFallbackValue(&result, col: col, row: row, type: colType)
                    ))
                }
            }

            rows.append(rowData)
        }

        let executionTime = Date().timeIntervalSince(startTime)

        return DuckDBRawResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            columnTypes: columnTypes,
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
        case DUCKDB_TYPE_GEOMETRY: return "GEOMETRY"
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
            return String(format: "\(formatYearISO(d.year))-%02d-%02d", d.month, d.day)

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

    static func patchCastedColumns(
        _ raw: inout DuckDBRawResult, query: String, connection: duckdb_connection
    ) {
        let patchedColIndices = raw.columnTypes.enumerated().compactMap { idx, type in
            requiresTextCast(type) ? idx : nil
        }
        guard !patchedColIndices.isEmpty, !raw.rows.isEmpty else { return }

        let castExprs = raw.columns.enumerated().map { i, name in
            projection(for: raw.columnTypes[i], column: name)
        }
        let wrappedQuery = buildWrappedQuery(originalQuery: query, castExprs: castExprs)

        var patchResult = duckdb_result()
        guard duckdb_query(connection, wrappedQuery, &patchResult) == DuckDBSuccess else { return }
        defer { duckdb_destroy_result(&patchResult) }

        let patchRowCount = min(duckdb_row_count(&patchResult), UInt64(raw.rows.count))
        for row in 0..<patchRowCount {
            for colIdx in patchedColIndices {
                if duckdb_value_is_null(&patchResult, idx_t(colIdx), row) {
                    raw.rows[Int(row)][colIdx] = .null
                } else if let ptr = duckdb_value_varchar(&patchResult, idx_t(colIdx), row) {
                    raw.rows[Int(row)][colIdx] = .text(String(cString: ptr))
                    duckdb_free(ptr)
                }
            }
        }
    }

    static func isNativelyRenderable(_ type: duckdb_type) -> Bool {
        switch type {
        case DUCKDB_TYPE_BOOLEAN,
             DUCKDB_TYPE_TINYINT, DUCKDB_TYPE_SMALLINT, DUCKDB_TYPE_INTEGER, DUCKDB_TYPE_BIGINT, DUCKDB_TYPE_HUGEINT,
             DUCKDB_TYPE_UTINYINT, DUCKDB_TYPE_USMALLINT, DUCKDB_TYPE_UINTEGER, DUCKDB_TYPE_UBIGINT, DUCKDB_TYPE_UHUGEINT,
             DUCKDB_TYPE_FLOAT, DUCKDB_TYPE_DOUBLE, DUCKDB_TYPE_DECIMAL,
             DUCKDB_TYPE_VARCHAR, DUCKDB_TYPE_BLOB, DUCKDB_TYPE_UUID, DUCKDB_TYPE_BIT, DUCKDB_TYPE_ENUM,
             DUCKDB_TYPE_DATE, DUCKDB_TYPE_TIME, DUCKDB_TYPE_TIME_NS, DUCKDB_TYPE_INTERVAL,
             DUCKDB_TYPE_TIMESTAMP, DUCKDB_TYPE_TIMESTAMP_S, DUCKDB_TYPE_TIMESTAMP_MS, DUCKDB_TYPE_TIMESTAMP_NS,
             DUCKDB_TYPE_LIST, DUCKDB_TYPE_STRUCT, DUCKDB_TYPE_MAP, DUCKDB_TYPE_ARRAY, DUCKDB_TYPE_UNION:
            return true
        default:
            return false
        }
    }

    static func requiresTextCast(_ type: duckdb_type) -> Bool {
        !isNativelyRenderable(type)
    }

    static func castExpression(for type: duckdb_type, column: String) -> String {
        let quoted = quoteIdentifier(column)
        if type == DUCKDB_TYPE_GEOMETRY {
            return "CASE WHEN \(quoted) IS NULL THEN NULL ELSE ST_AsText(\(quoted)) END AS \(quoted)"
        }
        return "CASE WHEN \(quoted) IS NULL THEN NULL ELSE CAST(\(quoted) AS VARCHAR) END AS \(quoted)"
    }

    static func projection(for type: duckdb_type, column: String) -> String {
        requiresTextCast(type) ? castExpression(for: type, column: column) : quoteIdentifier(column)
    }

    static func buildWrappedQuery(originalQuery: String, castExprs: [String]) -> String {
        var trimmed = originalQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(";") {
            trimmed = String(trimmed.dropLast())
        }
        return "SELECT \(castExprs.joined(separator: ", ")) FROM (\(trimmed)) AS _tp_cast"
    }

    static func quoteIdentifier(_ ident: String) -> String {
        "\"\(ident.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func formatTimestamp(_ ts: duckdb_timestamp) -> String {
        let parts = duckdb_from_timestamp(ts)
        let d = parts.date
        let t = parts.time
        let micros = t.micros % 1_000_000
        let yearPart = formatYearISO(d.year)
        if micros == 0 {
            return String(
                format: "\(yearPart)-%02d-%02d %02d:%02d:%02d",
                d.month, d.day, t.hour, t.min, t.sec
            )
        }
        return String(
            format: "\(yearPart)-%02d-%02d %02d:%02d:%02d.%06d",
            d.month, d.day, t.hour, t.min, t.sec, micros
        )
    }

    static func formatYearISO(_ year: Int32) -> String {
        if year < 0 {
            return String(format: "-%04d", -Int(year))
        }
        return String(format: "%04d", year)
    }

    private static func formatTime(_ t: duckdb_time_struct) -> String {
        let micros = t.micros % 1_000_000
        if micros == 0 {
            return String(format: "%02d:%02d:%02d", t.hour, t.min, t.sec)
        }
        return String(format: "%02d:%02d:%02d.%06d", t.hour, t.min, t.sec, micros)
    }

    static func formatHugeInt(upper: Int64, lower: UInt64) -> String {
        HugeIntFormatter.format(upper: upper, lower: lower)
    }

    static func formatUHugeInt(upper: UInt64, lower: UInt64) -> String {
        HugeIntFormatter.formatUnsigned(upper: upper, lower: lower)
    }
}

struct DuckDBRawResult: @unchecked Sendable {
    let columns: [String]
    let columnTypeNames: [String]
    let columnTypes: [duckdb_type]
    var rows: [[PluginCellValue]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}
