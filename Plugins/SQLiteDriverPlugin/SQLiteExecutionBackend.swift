//
//  SQLiteExecutionBackend.swift
//  TablePro
//

import Foundation
import os
import SQLite3
import TableProPluginKit

/// Where a SQLite driver's statements actually run.
///
/// A file-backed connection opens the database with the app's own `libsqlite3` (the local backend).
/// A connection whose database lives on an SSH server runs its statements on the server through a
/// small agent, because SQLite's file locking is only reliable for a process on the same host as
/// the file. Both answer the same driver, so every schema, metadata and write path is written once
/// against this protocol and neither knows which backend it is talking to.
protocol SQLiteExecutionBackend: Actor {
    /// The SQLite version that will run the statements: the app's library for a local file, the
    /// server's for a remote one. Cached at connect time; nil until then.
    nonisolated var resolvedServerVersion: String? { get }

    /// Ends a running statement, and a wait on a locked database, without waiting on the actor. A
    /// query holds the actor for its whole life, so cancel cannot be an actor-isolated method.
    nonisolated var canceller: SQLiteCanceller { get }

    func open() async throws
    func close() async

    /// Stops an in-flight `open()` without waiting on the actor, for a connect the user cancelled.
    /// `Task.cancel()` is cooperative and cannot interrupt a blocking wait, so the remote backend
    /// tears down its socket here; a local open has nothing to abort.
    nonisolated func abortConnect()

    func applyBusyTimeout(_ milliseconds: Int32) async

    /// What the session has open, so nothing the app owns opens a transaction over the user's.
    /// A backend that cannot ask keeps the `.unknown` default.
    func sessionTransactionState() async -> PluginSessionTransactionState

    func executeQuery(_ query: String) async throws -> SQLiteRawResult
    func executeParameterizedQuery(_ query: String, parameters: [PluginCellValue]) async throws -> SQLiteRawResult
    func streamQuery(
        _ query: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws
}

/// The one thing about a running query that must be reachable while the query holds the backend
/// actor: the request to stop it. The local backend interrupts the SQLite handle; the remote
/// backend writes a cancel frame to the agent.
protocol SQLiteCanceller: Sendable {
    func cancel()
}

extension SQLiteExecutionBackend {
    nonisolated func abortConnect() {}

    func sessionTransactionState() async -> PluginSessionTransactionState { .unknown }
}

struct SQLiteRawResult: Sendable {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[PluginCellValue]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}

// MARK: - Authorizer

/// Denies the SQLite functions that turn plain SQL into a native-code primitive on the machine
/// running the query. `fts3_tokenizer` registers an arbitrary pointer as a tokenizer from a bound
/// blob and dereferences it (measured: a SIGSEGV on the app's own libsqlite3 and on every server
/// build tried), and `load_extension` loads a shared library. Both are denied on every SQLite
/// connection, local or remote, so a crafted statement from the editor, an import, or an AI or MCP
/// client cannot reach them.
enum SQLiteAuthorizer {
    private static let function: Int32 = 31
    private static let denied: Set<String> = ["fts3_tokenizer", "load_extension"]

    private static let callback: @convention(c) (
        UnsafeMutableRawPointer?, Int32,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Int32 = { _, action, _, arg2, _, _ in
        guard action == function, let arg2 else { return SQLITE_OK }
        let name = String(cString: arg2).lowercased()
        return denied.contains(name) ? SQLITE_DENY : SQLITE_OK
    }

    static func install(on db: OpaquePointer?) {
        sqlite3_set_authorizer(db, callback, nil)
    }
}

// MARK: - Busy Wait

/// Ends a wait on a locked database when the user presses Stop, and after the configured timeout.
///
/// `sqlite3_busy_timeout` cannot do the first of those: it sleeps inside SQLite with nothing to
/// interrupt it, and `sqlite3_interrupt` does not reach a connection that is waiting for a lock
/// rather than running a statement. Measured against SQLite 3.54.0 with a second connection
/// holding `BEGIN EXCLUSIVE`: the interrupt was ignored and the waiter ran the full 60 seconds
/// before returning `SQLITE_BUSY`. A busy handler is the documented way to keep that decision,
/// because it is called back on every retry and stops the wait by returning zero.
///
/// Read and written from whichever thread is stepping a statement and from the caller of Stop, so
/// every access takes the lock.
final class SQLiteBusyState: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var timeoutMilliseconds: Int32 = 0

    /// How long one retry waits. Also the granularity at which Stop is noticed.
    static let retryIntervalMilliseconds: Int32 = 10

    func setTimeout(milliseconds: Int32) {
        lock.lock()
        defer { lock.unlock() }
        timeoutMilliseconds = milliseconds
    }

    func beginOperation() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = false
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
    }

    /// - Parameter retryCount: How many times SQLite has already called back for this lock.
    /// - Returns: `true` to wait and retry, `false` to give up and let the step return `SQLITE_BUSY`.
    func shouldRetry(afterRetryCount retryCount: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        guard timeoutMilliseconds > 0 else { return true }
        return retryCount * Self.retryIntervalMilliseconds < timeoutMilliseconds
    }
}

let sqliteBusyHandler: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32 = { context, retryCount in
    guard let context else { return 0 }
    let state = Unmanaged<SQLiteBusyState>.fromOpaque(context).takeUnretainedValue()
    guard state.shouldRetry(afterRetryCount: retryCount) else { return 0 }
    usleep(UInt32(SQLiteBusyState.retryIntervalMilliseconds) * 1_000)
    return 1
}

// MARK: - Local Backend

/// Interrupts the local SQLite handle from the Stop button. Holds the handle behind a lock because
/// the interrupting thread and the actor stepping the statement reach it at once.
final class SQLiteLocalCanceller: SQLiteCanceller, @unchecked Sendable {
    private let lock = NSLock()
    private let busyState: SQLiteBusyState
    private var handle: OpaquePointer?

    init(busyState: SQLiteBusyState) {
        self.busyState = busyState
    }

    func setHandle(_ handle: OpaquePointer?) {
        lock.lock()
        self.handle = handle
        lock.unlock()
    }

    func cancel() {
        busyState.cancel()
        lock.lock()
        let handle = self.handle
        lock.unlock()
        guard let handle else { return }
        sqlite3_interrupt(handle)
    }
}

/// Opens a SQLite database with the app's own `libsqlite3` and runs statements against it.
actor SQLiteLocalBackend: SQLiteExecutionBackend {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLiteLocalBackend")

    private var db: OpaquePointer?
    private let busyState: SQLiteBusyState
    private let path: String
    private let localCanceller: SQLiteLocalCanceller

    nonisolated let canceller: SQLiteCanceller
    nonisolated var resolvedServerVersion: String? { String(cString: sqlite3_libversion()) }

    init(path: String) {
        self.path = path
        let busyState = SQLiteBusyState()
        self.busyState = busyState
        let canceller = SQLiteLocalCanceller(busyState: busyState)
        self.localCanceller = canceller
        self.canceller = canceller
    }

    var isConnected: Bool { db != nil }

    func open() throws {
        let expandedPath = expandPath(path)
        if !FileManager.default.fileExists(atPath: expandedPath) {
            let directory = (expandedPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        let result = sqlite3_open(expandedPath, &db)
        if result != SQLITE_OK {
            let errorMessage = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            throw SQLitePluginError.connectionFailed(errorMessage)
        }
        SQLiteAuthorizer.install(on: db)
        installBusyHandler()
        localCanceller.setHandle(db)
    }

    func close() {
        localCanceller.setHandle(nil)
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    func applyBusyTimeout(_ milliseconds: Int32) {
        busyState.setTimeout(milliseconds: milliseconds)
    }

    /// `sqlite3_get_autocommit` is SQLite's own answer and costs no statement. Measured against
    /// SQLite 3.54.0: it reports 0 from a `BEGIN` until the matching `COMMIT` or `ROLLBACK`, and
    /// from a bare `SAVEPOINT`, which opens a transaction too. SQLite has no aborted state, since
    /// a failed statement leaves the transaction usable.
    func sessionTransactionState() -> PluginSessionTransactionState {
        guard let db else { return .unknown }
        return sqlite3_get_autocommit(db) == 0 ? .inTransaction : .idle
    }

    private func installBusyHandler() {
        guard let db else { return }
        sqlite3_busy_handler(db, sqliteBusyHandler, Unmanaged.passUnretained(busyState).toOpaque())
    }

    private func expandPath(_ path: String) -> String {
        path.hasPrefix("~") ? NSString(string: path).expandingTildeInPath : path
    }

    func executeQuery(_ query: String) throws -> SQLiteRawResult {
        try runStatement(query, parameters: nil)
    }

    func executeParameterizedQuery(_ query: String, parameters: [PluginCellValue]) throws -> SQLiteRawResult {
        try runStatement(query, parameters: parameters)
    }

    private func runStatement(_ query: String, parameters: [PluginCellValue]?) throws -> SQLiteRawResult {
        guard let db else { throw SQLitePluginError.notConnected }
        busyState.beginOperation()

        let startTime = Date()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLitePluginError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        if let parameters {
            try bind(parameters, to: statement, db: db)
        }

        let columnCount = sqlite3_column_count(statement)
        let (columns, columnTypeNames) = Self.columnMetadata(statement, count: columnCount)

        var rows: [[PluginCellValue]] = []
        var truncated = false
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if rows.count >= PluginRowLimits.emergencyMax {
                truncated = true
                break
            }
            rows.append(Self.readRow(statement, columnCount: columnCount))
            stepResult = sqlite3_step(statement)
        }

        if !truncated, stepResult != SQLITE_DONE {
            throw SQLitePluginError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        let rowsAffected = columns.isEmpty ? Int(sqlite3_changes(db)) : 0
        return SQLiteRawResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: rowsAffected,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: truncated
        )
    }

    func streamQuery(
        _ query: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) throws {
        busyState.beginOperation()
        guard let db else { throw SQLitePluginError.notConnected }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLitePluginError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        let columnCount = sqlite3_column_count(statement)
        let (columns, columnTypeNames) = Self.columnMetadata(statement, count: columnCount)
        continuation.yield(.header(PluginStreamHeader(
            columns: columns, columnTypeNames: columnTypeNames, estimatedRowCount: nil
        )))

        let batchSize = 5_000
        var batch: [PluginRow] = []
        batch.reserveCapacity(batchSize)

        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if Task.isCancelled {
                if !batch.isEmpty { continuation.yield(.rows(batch)) }
                sqlite3_finalize(statement)
                continuation.finish(throwing: CancellationError())
                return
            }
            batch.append(Self.readRow(statement, columnCount: columnCount))
            if batch.count >= batchSize {
                continuation.yield(.rows(batch))
                batch.removeAll(keepingCapacity: true)
            }
            stepResult = sqlite3_step(statement)
        }

        if !batch.isEmpty { continuation.yield(.rows(batch)) }

        guard stepResult == SQLITE_DONE else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(statement)
            continuation.finish(throwing: SQLitePluginError.queryFailed(message))
            return
        }
        sqlite3_finalize(statement)
        continuation.finish()
    }

    private func bind(_ parameters: [PluginCellValue], to statement: OpaquePointer?, db: OpaquePointer) throws {
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, param) in parameters.enumerated() {
            let bindIndex = Int32(index + 1)
            let bindResult: Int32
            switch param {
            case .null:
                bindResult = sqlite3_bind_null(statement, bindIndex)
            case .text(let stringValue):
                bindResult = sqlite3_bind_text(statement, bindIndex, stringValue, -1, sqliteTransient)
            case .bytes(let data):
                bindResult = data.withUnsafeBytes { rawBuffer -> Int32 in
                    sqlite3_bind_blob(statement, bindIndex, rawBuffer.baseAddress, Int32(data.count), sqliteTransient)
                }
            }
            if bindResult != SQLITE_OK {
                throw SQLitePluginError.queryFailed("Failed to bind parameter \(index): \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    private static func columnMetadata(_ statement: OpaquePointer?, count: Int32) -> ([String], [String]) {
        var columns: [String] = []
        var columnTypeNames: [String] = []
        for i in 0..<count {
            if let name = sqlite3_column_name(statement, i) {
                columns.append(String(cString: name))
            } else {
                columns.append("column_\(i)")
            }
            if let typePtr = sqlite3_column_decltype(statement, i) {
                columnTypeNames.append(String(cString: typePtr))
            } else {
                columnTypeNames.append("")
            }
        }
        return (columns, columnTypeNames)
    }

    private static func readRow(_ statement: OpaquePointer?, columnCount: Int32) -> [PluginCellValue] {
        var row: [PluginCellValue] = []
        for i in 0..<columnCount {
            let colType = sqlite3_column_type(statement, i)
            if colType == SQLITE_NULL {
                row.append(.null)
            } else if colType == SQLITE_BLOB {
                let byteCount = Int(sqlite3_column_bytes(statement, i))
                if byteCount > 0, let blobPtr = sqlite3_column_blob(statement, i) {
                    row.append(.bytes(Data(bytes: blobPtr, count: byteCount)))
                } else {
                    row.append(.bytes(Data()))
                }
            } else if let text = sqlite3_column_text(statement, i) {
                row.append(.text(String(cString: text)))
            } else {
                row.append(.null)
            }
        }
        return row
    }
}
