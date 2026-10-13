import CDuckDB
import Dispatch
import Foundation
import TableProDatabase
import TableProModels

nonisolated final class DuckDBDriver: DatabaseDriver, @unchecked Sendable {
    let actor = DuckDBActor()
    private let source: LocalDatabaseFileSource
    private let openMode: LocalDatabaseOpenMode
    private let fileAccess = LocalDatabaseFileAccess()
    private let stateLock = NSLock()
    private var currentSchemaName = "main"

    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }
    var serverVersion: String? { String(cString: duckdb_library_version()) }
    var holdsSuspensionBlockingResource: Bool { source != .inMemory }

    var currentSchema: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentSchemaName
    }

    init(source: LocalDatabaseFileSource, openMode: LocalDatabaseOpenMode = .existingOnly) {
        self.source = source
        self.openMode = openMode
    }

    // MARK: - Connection

    func connect() async throws {
        let path = try fileAccess.begin(source, openMode: openMode)
        do {
            try await actor.open(path: path)
        } catch {
            fileAccess.end()
            throw error
        }
        try? await actor.query("SET autoinstall_known_extensions=false")
        try? await actor.query("SET autoload_known_extensions=false")
    }

    func disconnect() async throws {
        await actor.close()
        fileAccess.end()
    }

    func ping() async throws -> Bool {
        _ = try await actor.query("SELECT 1")
        return true
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        let raw = try await actor.query(query)
        let columns = raw.columnNames.enumerated().map { index, name in
            ColumnInfo(
                name: name,
                typeName: index < raw.columnTypeNames.count ? raw.columnTypeNames[index] : "",
                ordinalPosition: index
            )
        }
        return QueryResult(
            columns: columns,
            rows: raw.rows,
            rowsAffected: raw.rowsAffected,
            executionTime: raw.executionTime,
            isTruncated: raw.isTruncated
        )
    }

    /// Runs off the actor: the actor is busy inside the query for as long as it runs.
    func cancelCurrentQuery() async throws {
        actor.interruptHandle.interrupt()
    }

    // MARK: - Transactions

    func beginTransaction() async throws {
        _ = try await actor.query("BEGIN TRANSACTION")
    }

    func commitTransaction() async throws {
        _ = try await actor.query("COMMIT")
    }

    func rollbackTransaction() async throws {
        _ = try await actor.query("ROLLBACK")
    }

    // MARK: - State

    func resolveSchema(_ schema: String?) -> String {
        if let schema { return schema }
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentSchemaName
    }

    func setCurrentSchema(_ schema: String) {
        stateLock.lock()
        currentSchemaName = schema
        stateLock.unlock()
    }
}

// MARK: - Interrupt Handle

/// The open connection, reachable without the actor so a cancel can interrupt the query the actor is running.
/// `duckdb_interrupt` on a disconnected connection reads freed memory, so the interrupt and the detach that precedes
/// `duckdb_disconnect` share one lock.
nonisolated final class DuckDBInterruptHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: duckdb_connection?
    private var runningStream: UInt64?

    func attach(_ connection: duckdb_connection) {
        lock.withLock { self.connection = connection }
    }

    func detach() {
        lock.withLock {
            connection = nil
            runningStream = nil
        }
    }

    /// The user's Stop, which ends whatever the connection is running.
    func interrupt() {
        lock.withLock {
            guard let connection else { return }
            duckdb_interrupt(connection)
        }
    }

    /// The editor and the data browser share this connection, so a stream's consumer interrupts only while that
    /// stream's own query is the one running.
    func interrupt(stream: UInt64) {
        lock.withLock {
            guard runningStream == stream, let connection else { return }
            duckdb_interrupt(connection)
        }
    }

    func enter(_ stream: UInt64) {
        lock.withLock { runningStream = stream }
    }

    func leave(_ stream: UInt64) {
        lock.withLock {
            if runningStream == stream { runningStream = nil }
        }
    }
}

// MARK: - DuckDB Actor (thread-safe C API access)

actor DuckDBActor {
    static let maxRows = 100_000

    private let queue = DispatchSerialQueue(label: "com.TablePro.duckdb")

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    nonisolated let interruptHandle = DuckDBInterruptHandle()
    private var database: duckdb_database?
    var connection: duckdb_connection?

    /// One result streams at a time. Each `beginStream` gets a new generation, so the producer of a stream that a
    /// later one replaced cannot fetch from or destroy the later result.
    var streamResult: duckdb_result?
    var streamColumns: [DuckDBStreamColumn] = []
    var streamGeneration: UInt64 = 0

    func open(path: String) throws {
        var db: duckdb_database?
        var errorPtr: UnsafeMutablePointer<CChar>?
        let state = duckdb_open_ext(path, &db, nil, &errorPtr)

        if state == DuckDBError {
            let detail: String
            if let errorPtr {
                detail = String(cString: errorPtr)
                duckdb_free(errorPtr)
            } else {
                detail = "unknown error"
            }
            throw DuckDBDriverError.connectionFailed(detail)
        }

        guard db != nil else {
            throw DuckDBDriverError.connectionFailed("Failed to open the DuckDB database")
        }

        var conn: duckdb_connection?
        if duckdb_connect(db, &conn) == DuckDBError {
            duckdb_close(&db)
            throw DuckDBDriverError.connectionFailed("Failed to create a DuckDB connection")
        }

        database = db
        connection = conn
        if let conn { interruptHandle.attach(conn) }
    }

    func close() {
        interruptHandle.detach()
        closeStreamResult()
        if connection != nil {
            duckdb_disconnect(&connection)
            connection = nil
        }
        if database != nil {
            duckdb_close(&database)
            database = nil
        }
    }

    func query(_ sql: String) throws -> DuckDBRawResult {
        guard let connection else { throw DuckDBDriverError.notConnected }
        // Another statement closes an open streaming result inside DuckDB, and its next fetch would fail with an
        // internal error. Closing it here ends that stream as cancelled.
        closeStreamResult()

        let startTime = Date()
        var result = duckdb_result()

        if duckdb_query(connection, sql, &result) == DuckDBError {
            let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "Unknown DuckDB error"
            duckdb_destroy_result(&result)
            throw DuckDBDriverError.queryFailed(message)
        }

        let columnCount = duckdb_column_count(&result)
        let rowsChanged = Int(duckdb_rows_changed(&result))
        var plan: [DuckDBStreamColumn] = []
        for index in 0..<columnCount {
            let name = duckdb_column_name(&result, index).map { String(cString: $0) } ?? "column_\(index)"
            let type = duckdb_column_type(&result, index)
            plan.append(DuckDBStreamColumn(
                name: name,
                typeName: Self.typeName(for: type),
                type: type,
                castToText: Self.requiresTextCast(type)
            ))
        }

        if columnCount == 0 {
            duckdb_destroy_result(&result)
            return DuckDBRawResult(
                columnNames: [],
                columnTypeNames: [],
                rows: [],
                rowsAffected: rowsChanged,
                executionTime: Date().timeIntervalSince(startTime),
                isTruncated: false
            )
        }

        if plan.contains(where: { $0.castToText }) {
            duckdb_destroy_result(&result)
            let wrapped = Self.castedQuery(originalQuery: sql, columns: plan)
            var recast = duckdb_result()
            if duckdb_query(connection, wrapped, &recast) == DuckDBError {
                let message = duckdb_result_error(&recast).map { String(cString: $0) } ?? "Unknown DuckDB error"
                duckdb_destroy_result(&recast)
                throw DuckDBDriverError.queryFailed(message)
            }
            result = recast
        }

        defer { duckdb_destroy_result(&result) }
        return Self.decodeMaterialized(&result, plan: plan, rowsChanged: rowsChanged, startTime: startTime)
    }

    private static func decodeMaterialized(
        _ result: inout duckdb_result,
        plan: [DuckDBStreamColumn],
        rowsChanged: Int,
        startTime: Date
    ) -> DuckDBRawResult {
        let options = StreamOptions(textTruncationBytes: Int.max, maxRows: maxRows)
        var rows: [[String?]] = []
        var truncated = false

        chunks: while true {
            var chunk = duckdb_fetch_chunk(result)
            guard chunk != nil else { break }
            defer { duckdb_destroy_data_chunk(&chunk) }

            let size = duckdb_data_chunk_get_size(chunk)
            var vectors: [duckdb_vector?] = []
            for index in 0..<plan.count {
                vectors.append(duckdb_data_chunk_get_vector(chunk, idx_t(index)))
            }
            for row in 0..<size {
                if rows.count >= maxRows {
                    truncated = true
                    break chunks
                }
                var values: [String?] = []
                values.reserveCapacity(plan.count)
                for index in 0..<plan.count {
                    guard let vector = vectors[index] else {
                        values.append(nil)
                        continue
                    }
                    values.append(cellText(decodeCell(vector: vector, row: row, column: plan[index], options: options)))
                }
                rows.append(values)
            }
        }

        return DuckDBRawResult(
            columnNames: plan.map(\.name),
            columnTypeNames: plan.map(\.typeName),
            rows: rows,
            rowsAffected: rowsChanged,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: truncated
        )
    }

    private static func cellText(_ cell: Cell) -> String? {
        switch cell {
        case .null: return nil
        case .text(let value): return value
        case .truncatedText(let prefix, _, _): return prefix
        case .binary: return nil
        }
    }

    // MARK: - Type Rendering

    static func castedQuery(originalQuery: String, columns: [DuckDBStreamColumn]) -> String {
        let projection = columns.map { column in
            column.castToText ? castExpression(for: column.type, column: column.name) : quoteIdentifier(column.name)
        }
        return "SELECT \(projection.joined(separator: ", ")) FROM (\(stripTrailingSemicolon(originalQuery))) AS _tp_cast"
    }

    private static func castExpression(for type: duckdb_type, column: String) -> String {
        let quoted = quoteIdentifier(column)
        if type == DUCKDB_TYPE_GEOMETRY {
            return "CASE WHEN \(quoted) IS NULL THEN NULL ELSE ST_AsText(\(quoted)) END AS \(quoted)"
        }
        return "CASE WHEN \(quoted) IS NULL THEN NULL ELSE CAST(\(quoted) AS VARCHAR) END AS \(quoted)"
    }

    static func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func stripTrailingSemicolon(_ query: String) -> String {
        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(";") {
            trimmed = String(trimmed.dropLast())
        }
        return trimmed
    }

    static func typeName(for type: duckdb_type) -> String {
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
        case DUCKDB_TYPE_UHUGEINT: return "UHUGEINT"
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
        case DUCKDB_TYPE_ARRAY: return "ARRAY"
        case DUCKDB_TYPE_UUID: return "UUID"
        case DUCKDB_TYPE_UNION: return "UNION"
        case DUCKDB_TYPE_BIT: return "BIT"
        case DUCKDB_TYPE_TIMESTAMP_TZ: return "TIMESTAMPTZ"
        case DUCKDB_TYPE_TIME_TZ: return "TIMETZ"
        case DUCKDB_TYPE_TIME_NS: return "TIME_NS"
        case DUCKDB_TYPE_GEOMETRY: return "GEOMETRY"
        default: return "VARCHAR"
        }
    }
}

nonisolated struct DuckDBRawResult: @unchecked Sendable {
    let columnNames: [String]
    let columnTypeNames: [String]
    let rows: [[String?]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}

// MARK: - Errors

nonisolated enum DuckDBDriverError: Error, LocalizedError {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message): return "DuckDB connection failed: \(message)"
        case .notConnected: return "Not connected to DuckDB database"
        case .queryFailed(let message): return "DuckDB query failed: \(message)"
        case .unsupported(let message): return message
        }
    }
}
