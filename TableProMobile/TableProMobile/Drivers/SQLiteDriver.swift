import Foundation
import SQLite3
import TableProDatabase
import TableProModels

nonisolated final class SQLiteDriver: DatabaseDriver, @unchecked Sendable {
    private let source: LocalDatabaseFileSource
    private let openMode: LocalDatabaseOpenMode
    private let fileAccess = LocalDatabaseFileAccess()
    private let actor = SQLiteActor()

    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }
    var supportsTransactions: Bool { true }
    var serverVersion: String? { String(cString: sqlite3_libversion()) }

    init(source: LocalDatabaseFileSource, openMode: LocalDatabaseOpenMode = .existingOnly) {
        self.source = source
        self.openMode = openMode
    }

    // MARK: - Connection

    func connect() async throws {
        let path = try fileAccess.begin(source, openMode: openMode)
        do {
            try await actor.open(path: path, flags: openFlags)
        } catch {
            fileAccess.end()
            throw error
        }
    }

    func disconnect() async throws {
        await actor.close()
        fileAccess.end()
    }

    private var openFlags: Int32 {
        guard openMode == .createNew || source == .inMemory else { return SQLITE_OPEN_READWRITE }
        return SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    }

    func ping() async throws -> Bool {
        _ = try await actor.execute("SELECT 1")
        return true
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> QueryResult {
        let raw = try await actor.execute(query)
        return QueryResult(
            columns: raw.columns.enumerated().map { i, name in
                ColumnInfo(
                    name: name,
                    typeName: i < raw.columnTypes.count ? raw.columnTypes[i] : "",
                    isPrimaryKey: false,
                    isNullable: true,
                    defaultValue: nil,
                    comment: nil,
                    characterMaxLength: nil,
                    ordinalPosition: i
                )
            },
            rows: raw.rows,
            rowsAffected: raw.rowsAffected,
            executionTime: raw.executionTime,
            isTruncated: raw.isTruncated,
            statusMessage: nil
        )
    }

    /// Runs off the actor: the actor is busy inside `sqlite3_step` for as long as the statement runs.
    func cancelCurrentQuery() async throws {
        actor.interruptHandle.interrupt()
    }

    func executeStreaming(query: String, options: StreamOptions) -> AsyncThrowingStream<StreamElement, Error> {
        let actor = self.actor
        let interruptHandle = actor.interruptHandle
        return AsyncThrowingStream { continuation in
            let stream = SQLiteStreamToken()
            let task = Task {
                do {
                    switch try await actor.beginStream(query: query, stream: stream) {
                    case .commandOk(let affectedRows):
                        if affectedRows != 0 {
                            continuation.yield(.rowsAffected(affectedRows))
                        }
                    case .rowSet(let columns):
                        continuation.yield(.columns(columns))
                        var emitted = 0
                        while !Task.isCancelled, emitted < options.maxRows {
                            guard let cells = try await actor.fetchNextRow(stream: stream, options: options, columns: columns) else {
                                break
                            }
                            continuation.yield(.row(Row(cells: cells)))
                            emitted += 1
                        }
                        if Task.isCancelled {
                            continuation.yield(.truncated(reason: .cancelled))
                        } else if emitted >= options.maxRows {
                            continuation.yield(.truncated(reason: .rowCap(options.maxRows)))
                        }
                        await actor.endStream(stream)
                    }
                    continuation.finish()
                } catch {
                    await actor.endStream(stream)
                    // A cancelled consumer interrupts the step, so the interrupt error is the cancel itself.
                    if error is CancellationError || Task.isCancelled {
                        continuation.yield(.truncated(reason: .cancelled))
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason {
                    interruptHandle.interrupt(stream)
                }
            }
        }
    }

    func sessionTransactionState() async -> DriverTransactionState {
        await actor.transactionState()
    }

    // MARK: - Schema

    func fetchTables(schema: String?) async throws -> [TableInfo] {
        let raw = try await actor.execute("""
            SELECT name, type FROM sqlite_master
            WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """)

        return raw.rows.compactMap { row in
            guard !row.isEmpty, let name = row[0] else { return nil }
            let kind: TableInfo.TableKind = (row.count > 1 ? row[1] : nil)?.lowercased() == "view" ? .view : .table
            return TableInfo(name: name, type: kind, rowCount: nil, dataSize: nil, comment: nil)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [ColumnInfo] {
        let safe = table.replacingOccurrences(of: "'", with: "''")
        let raw = try await actor.execute("PRAGMA table_info('\(safe)')")
        let createStatement = try await fetchCreateStatement(table: safe)

        let primaryKeyCount = raw.rows.filter { row in
            row.count >= 6 && ColumnMetadataRules.sqliteIsPrimaryKey(pk: row[5])
        }.count

        return raw.rows.enumerated().compactMap { index, row in
            guard row.count >= 6, let name = row[1], let dataType = row[2] else { return nil }
            let isPrimaryKey = ColumnMetadataRules.sqliteIsPrimaryKey(pk: row[5])
            return ColumnInfo(
                name: name,
                typeName: dataType,
                isPrimaryKey: isPrimaryKey,
                isNullable: row[3] == "0",
                defaultValue: row[4],
                comment: nil,
                characterMaxLength: nil,
                ordinalPosition: index,
                isAutoIncrement: ColumnMetadataRules.sqliteIsRowIdAlias(
                    typeName: dataType,
                    isPrimaryKey: isPrimaryKey,
                    primaryKeyCount: primaryKeyCount,
                    createStatement: createStatement
                )
            )
        }
    }

    private func fetchCreateStatement(table safeTable: String) async throws -> String? {
        let raw = try await actor.execute(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = '\(safeTable)'"
        )
        return raw.rows.first?.first ?? nil
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [IndexInfo] {
        let safe = table.replacingOccurrences(of: "'", with: "''")
        let raw = try await actor.execute("""
            SELECT il.name, il."unique", il.origin, ii.name AS col_name
            FROM pragma_index_list('\(safe)') il
            LEFT JOIN pragma_index_info(il.name) ii ON 1=1
            ORDER BY il.seq, ii.seqno
            """)

        var indexMap: [String: (isUnique: Bool, isPrimary: Bool, columns: [String])] = [:]
        var order: [String] = []

        for row in raw.rows {
            guard row.count >= 4, let indexName = row[0] else { continue }
            if indexMap[indexName] == nil {
                indexMap[indexName] = (
                    isUnique: row[1] == "1",
                    isPrimary: (row[2] ?? "c") == "pk",
                    columns: []
                )
                order.append(indexName)
            }
            if let col = row[3] {
                indexMap[indexName]?.columns.append(col)
            }
        }

        return order.compactMap { name in
            guard let entry = indexMap[name] else { return nil }
            return IndexInfo(
                name: name,
                columns: entry.columns,
                isUnique: entry.isUnique,
                isPrimary: entry.isPrimary,
                type: "BTREE"
            )
        }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [ForeignKeyInfo] {
        let safe = table.replacingOccurrences(of: "'", with: "''")
        let raw = try await actor.execute("PRAGMA foreign_key_list('\(safe)')")

        return raw.rows.compactMap { row in
            guard row.count >= 5,
                  let refTable = row[2],
                  let fromCol = row[3],
                  let toCol = row[4] else { return nil }

            return ForeignKeyInfo(
                name: "fk_\(table)_\(row[0] ?? "0")",
                column: fromCol,
                referencedTable: refTable,
                referencedColumn: toCol,
                onDelete: row.count >= 7 ? (row[6] ?? "NO ACTION") : "NO ACTION",
                onUpdate: row.count >= 6 ? (row[5] ?? "NO ACTION") : "NO ACTION"
            )
        }
    }

    func fetchDatabases() async throws -> [String] { [] }

    func switchDatabase(to name: String) async throws {
        throw SQLiteError.unsupported("SQLite does not support database switching")
    }

    func switchSchema(to name: String) async throws {
        throw SQLiteError.unsupported("SQLite does not support schemas")
    }

    func fetchSchemas() async throws -> [String] { [] }

    func beginTransaction() async throws {
        _ = try await actor.execute("BEGIN TRANSACTION")
    }

    func commitTransaction() async throws {
        _ = try await actor.execute("COMMIT")
    }

    func rollbackTransaction() async throws {
        _ = try await actor.execute("ROLLBACK")
    }
}

// MARK: - Interrupt Handle

/// Identifies one `executeStreaming` call, so the actor and the interrupt handle act only on the
/// statement that call began.
nonisolated final class SQLiteStreamToken: Sendable {}

/// The open connection, reachable without the actor so Stop can interrupt a statement the actor is
/// stepping. SQLite forbids `sqlite3_interrupt` on a connection that is closed or might close before
/// the call returns, so every interrupt and the detach that precedes `sqlite3_close` share one lock.
///
/// An interrupt stops every statement on the connection, and while any statement is active it also
/// stops the next one to start. The data browser and the query editor share a driver, so a stream's
/// consumer interrupts only while its own statement is stepping.
nonisolated final class SQLiteInterruptHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var steppingStream: SQLiteStreamToken?
    private var interruptedDuringStep = false

    func attach(_ db: OpaquePointer) {
        lock.withLock { self.db = db }
    }

    func detach() {
        lock.withLock { db = nil }
    }

    /// The user's Stop, which ends whatever is running.
    func interrupt() {
        lock.withLock {
            guard let db else { return }
            if steppingStream != nil { interruptedDuringStep = true }
            sqlite3_interrupt(db)
        }
    }

    /// Between steps the cancelled producer stops by itself, and an interrupt then would reach the
    /// next statement on the connection instead.
    func interrupt(_ stream: SQLiteStreamToken) {
        lock.withLock {
            guard let db, steppingStream === stream else { return }
            interruptedDuringStep = true
            sqlite3_interrupt(db)
        }
    }

    func beginStep(of stream: SQLiteStreamToken) {
        lock.withLock {
            steppingStream = stream
            interruptedDuringStep = false
        }
    }

    /// Returns whether an interrupt arrived while the step ran.
    func endStep() -> Bool {
        lock.withLock {
            defer {
                steppingStream = nil
                interruptedDuringStep = false
            }
            return interruptedDuringStep
        }
    }
}

// MARK: - SQLite Actor (thread-safe C API access)

private actor SQLiteActor {
    nonisolated let interruptHandle = SQLiteInterruptHandle()
    private var db: OpaquePointer?

    func open(path: String, flags: Int32) throws {
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            if let db { sqlite3_close(db) }
            self.db = nil
            throw SQLiteError.connectionFailed(msg)
        }
        sqlite3_busy_timeout(db, 5_000)
        if let db { interruptHandle.attach(db) }
    }

    /// `sqlite3_close` refuses a connection with an unfinalized statement and leaves it open, so a
    /// stream still in progress is finalized first.
    func close() {
        interruptHandle.detach()
        finalizeStreamingStatement()
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    /// SQLite has no implicit transaction to report: autocommit is off from a `BEGIN` or a bare
    /// `SAVEPOINT` until the matching `COMMIT` or `ROLLBACK`.
    func transactionState() -> DriverTransactionState {
        guard let db else { return .unknown }
        return sqlite3_get_autocommit(db) == 0 ? .explicitTransaction : .idle
    }

    func execute(_ query: String) throws -> RawResult {
        guard let db else { throw SQLiteError.notConnected }

        let start = Date()
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        // Text with only whitespace or comments prepares to no statement, and stepping nothing is a misuse.
        guard stmt != nil else {
            return RawResult(columns: [], columnTypes: [], rows: [],
                             rowsAffected: 0, executionTime: Date().timeIntervalSince(start), isTruncated: false)
        }

        let colCount = sqlite3_column_count(stmt)
        var columns: [String] = []
        var columnTypes: [String] = []

        for i in 0..<colCount {
            columns.append(sqlite3_column_name(stmt, i).map { String(cString: $0) } ?? "col_\(i)")
            columnTypes.append(sqlite3_column_decltype(stmt, i).map { String(cString: $0) } ?? "")
        }

        var rows: [[String?]] = []
        let maxRows = 100_000

        let totalChangesBefore = sqlite3_total_changes64(db)
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            if rows.count >= maxRows {
                return RawResult(columns: columns, columnTypes: columnTypes, rows: rows,
                                 rowsAffected: 0, executionTime: Date().timeIntervalSince(start), isTruncated: true)
            }

            var row: [String?] = []
            for i in 0..<colCount {
                if sqlite3_column_type(stmt, i) == SQLITE_NULL {
                    row.append(nil)
                } else if sqlite3_column_type(stmt, i) == SQLITE_BLOB {
                    let bytes = Int(sqlite3_column_bytes(stmt, i))
                    if bytes > 0, let ptr = sqlite3_column_blob(stmt, i) {
                        row.append(Data(bytes: ptr, count: bytes).base64EncodedString())
                    } else {
                        row.append("")
                    }
                } else if let text = sqlite3_column_text(stmt, i) {
                    row.append(String(cString: text))
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
            stepResult = sqlite3_step(stmt)
        }
        guard stepResult == SQLITE_DONE else {
            throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        let affected = columns.isEmpty ? changes(of: db, sinceTotal: totalChangesBefore) : 0
        return RawResult(columns: columns, columnTypes: columnTypes, rows: rows,
                         rowsAffected: affected, executionTime: Date().timeIntervalSince(start), isTruncated: false)
    }

    /// `sqlite3_changes64` keeps the count of the last INSERT, UPDATE or DELETE, so a statement that
    /// wrote nothing, DDL included, would report it again. The total moves only when this one wrote.
    private func changes(of db: OpaquePointer, sinceTotal totalBefore: Int64) -> Int {
        guard sqlite3_total_changes64(db) != totalBefore else { return 0 }
        return Int(sqlite3_changes64(db))
    }

    // MARK: - Streaming

    /// One statement streams at a time, held with the token of the stream that began it, so the
    /// producer of a stream that a later `beginStream` replaced cannot step or finalize the later one.
    private var streamingStmt: OpaquePointer?
    private var streamingToken: SQLiteStreamToken?

    func beginStream(query: String, stream: SQLiteStreamToken) throws -> SQLiteBeginStreamResult {
        guard let db else { throw SQLiteError.notConnected }
        // Stop can land while the stream waits for the actor, and an interrupt then reaches nothing.
        try Task.checkCancellation()
        finalizeStreamingStatement()

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard let stmt else {
            throw SQLiteError.queryFailed("Failed to prepare statement")
        }

        let colCount = Int(sqlite3_column_count(stmt))
        if colCount == 0 {
            defer { sqlite3_finalize(stmt) }
            let totalChangesBefore = sqlite3_total_changes64(db)
            let stepResult = try step(stmt, of: stream).result
            guard stepResult == SQLITE_DONE || stepResult == SQLITE_ROW else {
                throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            return .commandOk(affectedRows: changes(of: db, sinceTotal: totalChangesBefore))
        }

        var columns: [ColumnInfo] = []
        for i in 0..<colCount {
            let name = sqlite3_column_name(stmt, Int32(i)).map { String(cString: $0) } ?? "col_\(i)"
            let typeName = sqlite3_column_decltype(stmt, Int32(i)).map { String(cString: $0) } ?? ""
            columns.append(ColumnInfo(
                name: name,
                typeName: typeName,
                isPrimaryKey: false,
                isNullable: true,
                defaultValue: nil,
                comment: nil,
                characterMaxLength: nil,
                ordinalPosition: i
            ))
        }
        streamingStmt = stmt
        streamingToken = stream
        return .rowSet(columns)
    }

    /// A stream whose statement is gone, replaced by a later `beginStream` or finalized by a close,
    /// ends as cancelled rather than reading rows that belong to another statement.
    func fetchNextRow(stream: SQLiteStreamToken, options: StreamOptions, columns: [ColumnInfo]) throws -> [Cell]? {
        guard stream === streamingToken, let stmt = streamingStmt else { throw CancellationError() }
        let outcome = try step(stmt, of: stream)
        if outcome.interrupted, outcome.result == SQLITE_ROW {
            // The row was ready before the interrupt took effect, so the interrupt is still pending
            // and would stop the next statement on the connection unless this one ends now.
            finalizeStreamingStatement()
            throw CancellationError()
        }
        switch outcome.result {
        case SQLITE_ROW:
            break
        case SQLITE_DONE:
            return nil
        default:
            throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(sqlite3_db_handle(stmt))))
        }

        var cells: [Cell] = []
        cells.reserveCapacity(columns.count)
        for i in 0..<columns.count {
            let columnIndex = Int32(i)
            let columnType = sqlite3_column_type(stmt, columnIndex)
            switch columnType {
            case SQLITE_NULL:
                cells.append(.null)
            case SQLITE_BLOB:
                let bytes = Int(sqlite3_column_bytes(stmt, columnIndex))
                let ref = makeCellRef(column: columns[i].name, columns: columns, statement: stmt, options: options)
                cells.append(.binary(byteCount: bytes, ref: ref))
            default:
                if let text = sqlite3_column_text(stmt, columnIndex) {
                    let str = String(cString: text)
                    let ref = makeCellRef(column: columns[i].name, columns: columns, statement: stmt, options: options)
                    cells.append(Cell.from(
                        legacyValue: str,
                        columnTypeName: columns[i].typeName,
                        options: options,
                        ref: ref
                    ))
                } else {
                    cells.append(.null)
                }
            }
        }
        return cells
    }

    func endStream(_ stream: SQLiteStreamToken) {
        guard stream === streamingToken else { return }
        finalizeStreamingStatement()
    }

    private func finalizeStreamingStatement() {
        guard let stmt = streamingStmt else { return }
        sqlite3_finalize(stmt)
        streamingStmt = nil
        streamingToken = nil
    }

    /// Marks the step before reading the cancel, so a consumer that leaves at any moment is either
    /// seen here or finds its stream stepping and interrupts it.
    private func step(_ stmt: OpaquePointer, of stream: SQLiteStreamToken) throws -> (result: Int32, interrupted: Bool) {
        interruptHandle.beginStep(of: stream)
        guard !Task.isCancelled else {
            _ = interruptHandle.endStep()
            throw CancellationError()
        }
        let result = sqlite3_step(stmt)
        return (result, interruptHandle.endStep())
    }

    private func makeCellRef(column: String, columns: [ColumnInfo], statement: OpaquePointer, options: StreamOptions) -> CellRef? {
        guard let lazyContext = options.lazyContext, !lazyContext.primaryKeyColumns.isEmpty else { return nil }
        var pkComponents: [PrimaryKeyComponent] = []
        for pkColumn in lazyContext.primaryKeyColumns {
            guard let columnIndex = columns.firstIndex(where: { $0.name == pkColumn }) else { return nil }
            let idx = Int32(columnIndex)
            if sqlite3_column_type(statement, idx) == SQLITE_NULL {
                return nil
            }
            guard let text = sqlite3_column_text(statement, idx) else { return nil }
            pkComponents.append(PrimaryKeyComponent(column: pkColumn, value: String(cString: text)))
        }
        return CellRef(table: lazyContext.table, column: column, primaryKey: pkComponents)
    }
}

nonisolated enum SQLiteBeginStreamResult: Sendable {
    case rowSet([ColumnInfo])
    case commandOk(affectedRows: Int)
}

nonisolated private struct RawResult: Sendable {
    let columns: [String]
    let columnTypes: [String]
    let rows: [[String?]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}

// MARK: - Errors

nonisolated enum SQLiteError: Error, LocalizedError {
    case connectionFailed(String)
    case notConnected
    case queryFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "SQLite connection failed: \(msg)"
        case .notConnected: return "Not connected to SQLite database"
        case .queryFailed(let msg): return "SQLite query failed: \(msg)"
        case .unsupported(let msg): return msg
        }
    }
}
