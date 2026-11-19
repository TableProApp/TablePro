import CDuckDB
import Dispatch
import Foundation
import TableProDatabase
import TableProModels
import TableProSQLGrammar
import TableProSQLQuoting

nonisolated final class DuckDBDriver: DatabaseDriver, CatalogQuerying, ExportRowStreaming,
    DedicatedTransferConnection, @unchecked Sendable {
    let actor: DuckDBActor
    // A second connection on the session's database, which a transfer reads through; nil for the session itself.
    let transferLane: UInt64?
    let laneInterrupt: DuckDBInterruptHandle?
    private let source: LocalDatabaseFileSource
    private let openMode: LocalDatabaseOpenMode
    private let fileAccess = LocalDatabaseFileAccess()
    private let stateLock = NSLock()
    private var currentSchemaName = "main"

    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { true }
    var serverVersion: String? { String(cString: duckdb_library_version()) }
    // The session holds the file; a transfer connection lives and ends inside it.
    var holdsSuspensionBlockingResource: Bool { transferLane == nil && source != .inMemory }

    // DuckDB ends statement text at a NUL, so a NUL in a value goes in as chr(0) between two literals.
    func escapeStringLiteral(_ value: String) -> String {
        value.split(separator: "\0", omittingEmptySubsequences: false)
            .map { SQLQuoting.stringLiteralBody(String($0)) }
            .joined(separator: "'||chr(0)||'")
    }

    var currentSchema: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentSchemaName
    }

    init(source: LocalDatabaseFileSource, openMode: LocalDatabaseOpenMode = .existingOnly) {
        self.actor = DuckDBActor()
        self.transferLane = nil
        self.laneInterrupt = nil
        self.source = source
        self.openMode = openMode
    }

    init(transferOn actor: DuckDBActor, lane: UInt64, interrupt: DuckDBInterruptHandle, source: LocalDatabaseFileSource) {
        self.actor = actor
        self.transferLane = lane
        self.laneInterrupt = interrupt
        self.source = source
        self.openMode = .existingOnly
    }

    // MARK: - Connection

    func connect() async throws {
        guard transferLane == nil else { return }
        let path = try fileAccess.begin(source, openMode: openMode)
        do {
            try await actor.open(path: path)
        } catch {
            fileAccess.end()
            throw error
        }
    }

    func disconnect() async throws {
        if let transferLane {
            await actor.closeTransferLane(transferLane)
            return
        }
        await actor.close()
        fileAccess.end()
    }

    // In-process, so an open handle is a live session; an aborted transaction refuses every statement until ROLLBACK.
    func ping() async throws -> Bool {
        guard await actor.isOpen(lane: transferLane) else { throw DuckDBDriverError.notConnected }
        return true
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        let raw = try await actor.query(query, lane: transferLane)
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
        (laneInterrupt ?? actor.interruptHandle).interrupt()
    }

    // MARK: - Transactions

    func beginTransaction() async throws {
        _ = try await actor.query("BEGIN TRANSACTION", lane: transferLane)
    }

    func commitTransaction() async throws {
        _ = try await actor.query("COMMIT", lane: transferLane)
    }

    func rollbackTransaction() async throws {
        _ = try await actor.query("ROLLBACK", lane: transferLane)
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

    private let executor = DuckDBStackExecutor(name: "com.TablePro.duckdb")

    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    nonisolated let interruptHandle = DuckDBInterruptHandle()
    private(set) var database: duckdb_database?
    var connection: duckdb_connection?
    private var taskThreads: DuckDBTaskThreads?
    // The transfer connections on `database`, which `close()` ends before the database.
    var transferLanes: [UInt64: DuckDBTransferLane] = [:]
    var lastTransferLane: UInt64 = 0

    /// One result streams at a time. Each `beginStream` gets a new generation, so the producer of a stream that a
    /// later one replaced cannot fetch from or destroy the later result.
    var streamResult: duckdb_result?
    var streamColumns: [DuckDBStreamColumn] = []
    var streamGeneration: UInt64 = 0

    // The linked extensions, core_functions among them, exist only once DuckDB's generated loader has registered them.
    private nonisolated static let registeredExtensions: Int32 = duckdb_register_static_extensions()

    // v0.10.2 is DuckDB 1.x's default, so a file this creates stays readable by DuckDB 1.x (macOS:
    // DuckDBStorageCompatibility). Automatic installs stay off: iOS may not load downloaded code.
    private nonisolated static let openOptions = [
        ("storage_compatibility_version", "v0.10.2"),
        ("autoinstall_known_extensions", "false"),
        ("autoload_known_extensions", "false"),
        (DuckDBExpressionDepth.configurationOption, DuckDBExpressionDepth.limit),
    ] + DuckDBTaskThreads.sessionOptions

    func open(path: String) throws {
        _ = Self.registeredExtensions
        var config: duckdb_config?
        guard duckdb_create_config(&config) != DuckDBError else {
            throw DuckDBDriverError.connectionFailed("Failed to allocate a DuckDB configuration")
        }
        defer { duckdb_destroy_config(&config) }
        for (option, value) in Self.openOptions where duckdb_set_config(config, option, value) == DuckDBError {
            throw DuckDBDriverError.connectionFailed("DuckDB refused \(option) = \(value)")
        }

        var db: duckdb_database?
        var errorPtr: UnsafeMutablePointer<CChar>?
        let state = duckdb_open_ext(path, &db, config, &errorPtr)

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
        if let db { taskThreads = DuckDBTaskThreads(database: db) }
        if let conn { interruptHandle.attach(conn) }
    }

    var isOpen: Bool { database != nil && connection != nil }

    func isOpen(lane: UInt64?) -> Bool {
        guard let lane else { return isOpen }
        return database != nil && transferLanes[lane] != nil
    }

    // A connection left open after `duckdb_close` keeps reading the file, so each transfer connection goes first.
    func close() {
        closeTransferLanes()
        interruptHandle.detach()
        closeStreamResult()
        if connection != nil {
            duckdb_disconnect(&connection)
            connection = nil
        }
        taskThreads?.close()
        taskThreads = nil
        if database != nil {
            duckdb_close(&database)
            database = nil
        }
    }

    func query(_ sql: String, lane: UInt64? = nil) throws -> DuckDBRawResult {
        guard let connection = connection(for: lane) else { throw DuckDBDriverError.notConnected }
        // Another statement closes an open streaming result inside DuckDB, and its next fetch would fail with an
        // internal error. Closing it here ends that stream as cancelled.
        if let lane {
            closeExportResult(lane: lane)
        } else {
            closeStreamResult()
        }

        let startTime = Date()
        var result = duckdb_result()

        if let message = run(sql, on: connection, into: &result) {
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

    // Several statements run one at a time, split as the editor splits them, so a count one raises is taken over
    // before the next runs, and a text DuckDB cannot parse runs none of them. The result is the one duckdb_query
    // gives: the first with rows, else the last. Returns the error.
    func run(_ sql: String, on connection: duckdb_connection, into result: inout duckdb_result) -> String? {
        guard let taskThreads else {
            return duckdb_query(connection, sql, &result) == DuckDBError ? Self.error(of: &result) : nil
        }
        var extracted: duckdb_extracted_statements?
        defer { duckdb_destroy_extracted(&extracted) }
        let count = duckdb_extract_statements(connection, sql, &extracted)
        if let error = duckdb_extract_statements_error(extracted) {
            return String(cString: error)
        }
        guard count > 1 else { return Self.run(sql, on: connection, taskThreads, into: &result) }
        let statements = SQLStatementScanner.executableStatements(in: sql, grammar: Self.grammar)
        guard statements.count == count else {
            return "DuckDB reads \(count) statements here where TablePro splits \(statements.count); run them one at a time"
        }
        var kept: duckdb_result?
        var keptHasRows = false
        for statement in statements {
            var current = duckdb_result()
            if let failure = Self.run(statement.sql, on: connection, taskThreads, into: &current) {
                duckdb_destroy_result(&current)
                if var kept { duckdb_destroy_result(&kept) }
                return failure
            }
            if kept != nil, keptHasRows {
                duckdb_destroy_result(&current)
                continue
            }
            if var earlier = kept { duckdb_destroy_result(&earlier) }
            keptHasRows = duckdb_result_return_type(current) == DUCKDB_RESULT_TYPE_QUERY_RESULT
            kept = current
        }
        if let kept { result = kept }
        return nil
    }

    func followThreadCount(after type: duckdb_statement_type) {
        guard !DuckDBTaskThreads.keepsCount(type) else { return }
        taskThreads?.followCount()
    }

    private static let grammar = SQLLexicalReadings.resolve(
        databaseTypeId: DatabaseType.duckdb.rawValue, declared: nil, session: nil
    ).execution

    private static func run(
        _ sql: String,
        on connection: duckdb_connection,
        _ taskThreads: DuckDBTaskThreads,
        into result: inout duckdb_result
    ) -> String? {
        let state = duckdb_query(connection, sql, &result)
        if !DuckDBTaskThreads.keepsCount(duckdb_result_statement_type(result)) {
            taskThreads.followCount()
        }
        return state == DuckDBError ? error(of: &result) : nil
    }

    private static func error(of result: inout duckdb_result) -> String {
        duckdb_result_error(&result).map { String(cString: $0) } ?? "Unknown DuckDB error"
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
        SQLQuoting.identifier(identifier)
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
