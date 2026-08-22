//
//  DuckDBConnection.swift
//  DuckDBDriverPlugin
//

import CDuckDB
import Foundation
import os
import TableProPluginKit

/// Hands the open connection pointer out of the actor so a cancel can interrupt the query that is
/// running on it. libduckdb documents `duckdb_interrupt` as the one call safe from another thread.
struct InterruptHandle: @unchecked Sendable {
    let connection: duckdb_connection?
}

actor DuckDBConnectionActor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DuckDBConnectionActor")

    private var database: duckdb_database?
    private var connection: duckdb_connection?

    var isConnected: Bool { connection != nil }

    var connectionHandleForInterrupt: InterruptHandle { InterruptHandle(connection: connection) }

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
        var resolved = try Self.resolvedResult(query: query, parameters: [], connection: conn)
        defer { duckdb_destroy_result(&resolved.result) }
        return Self.extractResult(from: &resolved.result, schema: resolved.schema, startTime: startTime)
    }

    func executePrepared(_ query: String, parameters: [PluginCellValue]) throws -> DuckDBRawResult {
        guard let conn = connection else {
            throw DuckDBPluginError.notConnected
        }

        let startTime = Date()
        var resolved = try Self.resolvedResult(query: query, parameters: parameters, connection: conn)
        defer { duckdb_destroy_result(&resolved.result) }
        return Self.extractResult(from: &resolved.result, schema: resolved.schema, startTime: startTime)
    }

    func streamQuery(
        _ query: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) throws {
        guard let conn = connection else {
            throw DuckDBPluginError.notConnected
        }

        var resolved = try Self.resolvedResult(query: query, parameters: [], connection: conn)
        defer { duckdb_destroy_result(&resolved.result) }
        try Self.streamResultRows(&resolved.result, schema: resolved.schema, continuation: continuation)
    }

    // MARK: - Projection planning

    private enum ResultProjection {
        case unprojected
        case projected(sql: String, schema: ColumnSchema)
        case deferred
    }

    private static func resolvedResult(
        query: String, parameters: [PluginCellValue], connection: duckdb_connection
    ) throws -> (result: duckdb_result, schema: ColumnSchema) {
        var statement: duckdb_prepared_statement?
        let projection = resolveProjection(query: query, connection: connection, statement: &statement)
        defer { duckdb_destroy_prepare(&statement) }

        if case .projected(let sql, let schema) = projection,
           let projected = projectedResult(sql: sql, schema: schema, parameters: parameters, on: connection) {
            return (projected, schema)
        }

        var result = try runStatement(statement, query: query, parameters: parameters, on: connection)
        let schema = self.schema(of: &result)

        guard let sql = rereadProjection(query: query, schema: schema, projection: projection, result: result),
              let projected = projectedResult(sql: sql, schema: schema, parameters: parameters, on: connection)
        else {
            return (result, schema)
        }

        duckdb_destroy_result(&result)
        return (projected, schema)
    }

    private static func projectedResult(
        sql: String, schema: ColumnSchema, parameters: [PluginCellValue], on connection: duckdb_connection
    ) -> duckdb_result? {
        guard var projected = try? runPrepared(sql, parameters: parameters, on: connection) else {
            logger.warning("DuckDB could not read a result through a text projection, using the raw result")
            return nil
        }
        guard duckdb_column_count(&projected) == idx_t(schema.names.count) else {
            logger.warning("DuckDB text projection returned an unexpected column count, using the raw result")
            duckdb_destroy_result(&projected)
            return nil
        }
        return projected
    }

    private static func resolveProjection(
        query: String, connection: duckdb_connection, statement: inout duckdb_prepared_statement?
    ) -> ResultProjection {
        let state = duckdb_prepare(connection, query, &statement)

        guard state != DuckDBError, let stmt = statement else { return .unprojected }
        guard duckdb_prepared_statement_type(stmt) == DUCKDB_STATEMENT_TYPE_SELECT else { return .unprojected }

        let columnCount = duckdb_prepared_statement_column_count(stmt)
        guard columnCount > 0 else { return .unprojected }

        var names: [String] = []
        var logicalTypes: [DuckDBLogicalType?] = []
        for index in 0..<columnCount {
            let rawType = duckdb_prepared_statement_column_type(stmt, index)
            guard rawType != DUCKDB_TYPE_INVALID else { return .deferred }
            names.append(preparedColumnName(stmt, at: index))
            logicalTypes.append(logicalType(for: rawType))
        }

        let schema = ColumnSchema(names: names, logicalTypes: logicalTypes)
        guard DuckDBLogicalType.requiresTextProjection(anyOf: logicalTypes) else { return .unprojected }
        guard let sql = DuckDBProjectedQuery.build(originalQuery: query, columns: schema.projectionColumns) else {
            return .deferred
        }
        return .projected(sql: sql, schema: schema)
    }

    /// A prepared SELECT is planned before it runs, but a statement DuckDB could not prepare,
    /// and one it typed as anything other than SELECT, arrives here unplanned. Its real column
    /// types are only known now, and the deprecated value API faults on several of them, so the
    /// result is re-read through a text projection.
    ///
    /// `duckdb_result_statement_type` is the gate, because the projection runs the query a
    /// second time: re-running `INSERT ... RETURNING` would insert a second row.
    private static func rereadProjection(
        query: String, schema: ColumnSchema, projection: ResultProjection, result: duckdb_result
    ) -> String? {
        if case .projected = projection { return nil }
        guard DuckDBLogicalType.requiresTextProjection(anyOf: schema.logicalTypes) else { return nil }
        guard duckdb_result_statement_type(result) == DUCKDB_STATEMENT_TYPE_SELECT else { return nil }
        return DuckDBProjectedQuery.build(originalQuery: query, columns: schema.projectionColumns)
    }

    /// Reading any column of a result that holds one of these types through `duckdb_value_*`
    /// crashes the process, not just that column: a UUID at index 0 makes the INTEGER at index 1
    /// fault with SIGSEGV. `INSERT ... RETURNING a_uuid, id` is the reachable case, because a
    /// mutation cannot be re-run through a text projection.
    ///
    /// A type `logicalType(for:)` does not map counts as faulting, matching what
    /// `requiresTextProjection` already does with the same `nil`. `duckdb.h` carries several
    /// the table does not list (`VARINT`, `ANY`, `SQLNULL`, the literal types) and a libduckdb
    /// bump can add more, so the unknown case has to fail toward the safe side: dropping a row
    /// is recoverable and taking the process down is not.
    private static func valueAPIFaultsOnRow(_ types: [duckdb_type]) -> Bool {
        types.contains { type in
            guard let logical = logicalType(for: type) else { return true }
            return DuckDBLogicalType.typesTheValueAPICannotRender.contains(logical)
        }
    }

    private static func preparedColumnName(_ stmt: duckdb_prepared_statement, at index: idx_t) -> String {
        guard let pointer = duckdb_prepared_statement_column_name(stmt, index) else { return "column_\(index)" }
        let name = String(cString: pointer)
        duckdb_free(UnsafeMutableRawPointer(mutating: pointer))
        return name
    }

    // MARK: - Execution

    private static func runStatement(
        _ statement: duckdb_prepared_statement?,
        query: String,
        parameters: [PluginCellValue],
        on connection: duckdb_connection
    ) throws -> duckdb_result {
        guard let statement else {
            guard parameters.isEmpty else { return try runPrepared(query, parameters: parameters, on: connection) }
            return try runQuery(query, on: connection)
        }

        try bind(parameters, to: statement)

        var result = duckdb_result()
        guard duckdb_execute_prepared(statement, &result) != DuckDBError else {
            let message = errorMessage(from: &result)
            duckdb_destroy_result(&result)
            throw DuckDBPluginError.queryFailed(message)
        }
        return result
    }

    private static func runQuery(_ sql: String, on connection: duckdb_connection) throws -> duckdb_result {
        var result = duckdb_result()
        guard duckdb_query(connection, sql, &result) != DuckDBError else {
            let message = errorMessage(from: &result)
            duckdb_destroy_result(&result)
            throw DuckDBPluginError.queryFailed(message)
        }
        return result
    }

    private static func runPrepared(
        _ sql: String, parameters: [PluginCellValue], on connection: duckdb_connection
    ) throws -> duckdb_result {
        var stmtOpt: duckdb_prepared_statement?
        let prepareState = duckdb_prepare(connection, sql, &stmtOpt)
        defer { duckdb_destroy_prepare(&stmtOpt) }

        guard prepareState != DuckDBError, let stmt = stmtOpt else {
            var message = "Failed to prepare statement"
            if let failed = stmtOpt, let pointer = duckdb_prepare_error(failed) {
                message = String(cString: pointer)
            }
            throw DuckDBPluginError.queryFailed(message)
        }

        try bind(parameters, to: stmt)

        var result = duckdb_result()
        guard duckdb_execute_prepared(stmt, &result) != DuckDBError else {
            let message = errorMessage(from: &result)
            duckdb_destroy_result(&result)
            throw DuckDBPluginError.queryFailed(message)
        }
        return result
    }

    private static func bind(_ parameters: [PluginCellValue], to stmt: duckdb_prepared_statement) throws {
        for (index, parameter) in parameters.enumerated() {
            let position = idx_t(index + 1)
            let state: duckdb_state
            switch parameter {
            case .null:
                state = duckdb_bind_null(stmt, position)
            case .text(let value):
                state = duckdb_bind_varchar(stmt, position, value)
            case .bytes(let data):
                state = data.withUnsafeBytes { buffer -> duckdb_state in
                    guard let baseAddress = buffer.baseAddress else {
                        return duckdb_bind_null(stmt, position)
                    }
                    return duckdb_bind_blob(stmt, position, baseAddress, idx_t(data.count))
                }
            }
            if state == DuckDBError {
                throw DuckDBPluginError.queryFailed("Failed to bind parameter at index \(index)")
            }
        }
    }

    private static func errorMessage(from result: inout duckdb_result) -> String {
        guard let pointer = duckdb_result_error(&result) else { return "Unknown DuckDB error" }
        return String(cString: pointer)
    }

    // MARK: - Extraction

    private struct ColumnSchema {
        let names: [String]
        let logicalTypes: [DuckDBLogicalType?]

        var typeNames: [String] {
            logicalTypes.map { $0?.displayName ?? DuckDBLogicalType.varchar.displayName }
        }

        var projectionColumns: [(name: String, type: DuckDBLogicalType?)] {
            Array(zip(names, logicalTypes)).map { (name: $0.0, type: $0.1) }
        }
    }

    private static func schema(of result: inout duckdb_result) -> ColumnSchema {
        let columnCount = duckdb_column_count(&result)
        var names: [String] = []
        var logicalTypes: [DuckDBLogicalType?] = []

        for index in 0..<columnCount {
            if let pointer = duckdb_column_name(&result, index) {
                names.append(String(cString: pointer))
            } else {
                names.append("column_\(index)")
            }
            logicalTypes.append(logicalType(for: duckdb_column_type(&result, index)))
        }

        return ColumnSchema(names: names, logicalTypes: logicalTypes)
    }

    private static func extractResult(
        from result: inout duckdb_result,
        schema: ColumnSchema,
        startTime: Date
    ) -> DuckDBRawResult {
        let rowCount = duckdb_row_count(&result)
        let rowsChanged = duckdb_rows_changed(&result)
        let resultTypes = storageTypes(of: &result)

        // `INSERT ... RETURNING` reports rows_changed as 0 and puts the count in row_count
        // (measured: 2 and 0 for a two-row insert), so the row count is what actually
        // happened. Reporting rows_changed here would tell the user nothing was written.
        if valueAPIFaultsOnRow(resultTypes) {
            logger.error(
                "DuckDB returned a column the value API cannot read from a statement that cannot be re-read through a projection; reporting the row count without the rows"
            )
            return DuckDBRawResult(
                columns: schema.names,
                columnTypeNames: schema.typeNames,
                rows: [],
                rowsAffected: Int(rowsChanged > 0 ? rowsChanged : rowCount),
                executionTime: Date().timeIntervalSince(startTime),
                isTruncated: false
            )
        }

        let maxRows = min(rowCount, UInt64(PluginRowLimits.emergencyMax))
        var rows: [[PluginCellValue]] = []
        rows.reserveCapacity(Int(maxRows))
        var undecodableColumns: Set<idx_t> = []

        for row in 0..<maxRows {
            rows.append(extractRow(
                from: &result, row: row, resultTypes: resultTypes, undecodableColumns: &undecodableColumns
            ))
        }

        return DuckDBRawResult(
            columns: schema.names,
            columnTypeNames: schema.typeNames,
            rows: rows,
            rowsAffected: Int(rowsChanged),
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: rowCount > UInt64(PluginRowLimits.emergencyMax)
        )
    }

    private static func streamResultRows(
        _ result: inout duckdb_result,
        schema: ColumnSchema,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) throws {
        let rowCount = duckdb_row_count(&result)
        let resultTypes = storageTypes(of: &result)

        continuation.yield(.header(PluginStreamHeader(
            columns: schema.names,
            columnTypeNames: schema.typeNames,
            estimatedRowCount: Int(rowCount)
        )))

        if valueAPIFaultsOnRow(resultTypes) {
            logger.error(
                "DuckDB returned a column the value API cannot read from an unprojectable statement; streaming no rows"
            )
            continuation.finish()
            return
        }

        let maxRows = min(rowCount, UInt64(PluginRowLimits.emergencyMax))
        if rowCount > UInt64(PluginRowLimits.emergencyMax) {
            logger.warning("streamQuery truncating result from \(rowCount) to \(maxRows) rows")
        }

        var undecodableColumns: Set<idx_t> = []
        for row in 0..<maxRows {
            if Task.isCancelled {
                continuation.finish(throwing: CancellationError())
                return
            }
            continuation.yield(.rows([extractRow(
                from: &result, row: row, resultTypes: resultTypes, undecodableColumns: &undecodableColumns
            )]))
        }

        continuation.finish()
    }

    private static func storageTypes(of result: inout duckdb_result) -> [duckdb_type] {
        (0..<duckdb_column_count(&result)).map { duckdb_column_type(&result, $0) }
    }

    private static func extractRow(
        from result: inout duckdb_result,
        row: idx_t,
        resultTypes: [duckdb_type],
        undecodableColumns: inout Set<idx_t>
    ) -> [PluginCellValue] {
        var rowData: [PluginCellValue] = []
        rowData.reserveCapacity(resultTypes.count)

        for (index, columnType) in resultTypes.enumerated() {
            let column = idx_t(index)
            if duckdb_value_is_null(&result, column, row) {
                rowData.append(.null)
            } else if columnType == DUCKDB_TYPE_BLOB {
                let blob = duckdb_value_blob(&result, column, row)
                if let pointer = blob.data {
                    rowData.append(.bytes(Data(bytes: pointer, count: Int(blob.size))))
                } else {
                    rowData.append(.bytes(Data()))
                }
                duckdb_free(blob.data)
            } else if let pointer = duckdb_value_varchar(&result, column, row) {
                rowData.append(.text(String(cString: pointer)))
                duckdb_free(pointer)
            } else {
                if undecodableColumns.insert(column).inserted {
                    logger.warning(
                        "DuckDB value API cannot render column \(column) of type id \(columnType.rawValue)"
                    )
                }
                rowData.append(.null)
            }
        }

        return rowData
    }

    static func logicalType(for type: duckdb_type) -> DuckDBLogicalType? {
        switch type {
        case DUCKDB_TYPE_BOOLEAN: return .boolean
        case DUCKDB_TYPE_TINYINT: return .tinyint
        case DUCKDB_TYPE_SMALLINT: return .smallint
        case DUCKDB_TYPE_INTEGER: return .integer
        case DUCKDB_TYPE_BIGINT: return .bigint
        case DUCKDB_TYPE_UTINYINT: return .utinyint
        case DUCKDB_TYPE_USMALLINT: return .usmallint
        case DUCKDB_TYPE_UINTEGER: return .uinteger
        case DUCKDB_TYPE_UBIGINT: return .ubigint
        case DUCKDB_TYPE_FLOAT: return .float
        case DUCKDB_TYPE_DOUBLE: return .double
        case DUCKDB_TYPE_DECIMAL: return .decimal
        case DUCKDB_TYPE_HUGEINT: return .hugeint
        case DUCKDB_TYPE_UHUGEINT: return .uhugeint
        case DUCKDB_TYPE_VARCHAR: return .varchar
        case DUCKDB_TYPE_BLOB: return .blob
        case DUCKDB_TYPE_DATE: return .date
        case DUCKDB_TYPE_TIME: return .time
        case DUCKDB_TYPE_TIME_NS: return .timeNs
        case DUCKDB_TYPE_INTERVAL: return .interval
        case DUCKDB_TYPE_TIMESTAMP: return .timestamp
        case DUCKDB_TYPE_TIMESTAMP_S: return .timestampSeconds
        case DUCKDB_TYPE_TIMESTAMP_MS: return .timestampMilliseconds
        case DUCKDB_TYPE_TIMESTAMP_NS: return .timestampNanoseconds
        case DUCKDB_TYPE_TIMESTAMP_TZ: return .timestampTz
        case DUCKDB_TYPE_TIME_TZ: return .timeTz
        case DUCKDB_TYPE_BIT: return .bit
        case DUCKDB_TYPE_UUID: return .uuid
        case DUCKDB_TYPE_ENUM: return .enumeration
        case DUCKDB_TYPE_LIST: return .list
        case DUCKDB_TYPE_ARRAY: return .array
        case DUCKDB_TYPE_STRUCT: return .structure
        case DUCKDB_TYPE_MAP: return .map
        case DUCKDB_TYPE_UNION: return .union
        case DUCKDB_TYPE_BIGNUM: return .bignum
        case DUCKDB_TYPE_GEOMETRY: return .geometry
        default: return nil
        }
    }
}

struct DuckDBRawResult: @unchecked Sendable {
    let columns: [String]
    let columnTypeNames: [String]
    var rows: [[PluginCellValue]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}
