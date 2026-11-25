//
//  SQLiteExecutionBackend.swift
//  TablePro
//

#if os(iOS)
import SQLite3
#else
import CSQLite
#endif
import Foundation
import os
import TableProPluginKit
import TableProSQLiteCore

/// Where a SQLite driver's statements actually run.
///
/// A file-backed connection opens the database with the app's own `libsqlite3` (the local backend).
/// A connection whose database lives on an SSH server runs its statements on the server through a
/// small agent, because SQLite's file locking is only reliable for a process on the same host as
/// the file. Both answer the same driver, so every schema, metadata and write path is written once
/// against this protocol and neither knows which backend it is talking to.
nonisolated protocol SQLiteExecutionBackend: Actor {
    /// The SQLite version that will run the statements: the app's library for a local file, the
    /// server's for a remote one. Cached at connect time; nil until then.
    nonisolated var resolvedServerVersion: String? { get }

    /// Ends a running statement, and a wait on a locked database, without waiting on the actor. A
    /// query holds the actor for its whole life, so cancel cannot be an actor-isolated method.
    nonisolated var canceller: SQLiteCanceller { get }

    /// Opens the database and loads `extensions` into it, in order, before any statement runs.
    func open(loading extensions: [LoadableExtension]) async throws
    func close() async

    /// Stops an in-flight `open()` without waiting on the actor, for a connect the user cancelled.
    /// `Task.cancel()` is cooperative and cannot interrupt a blocking wait, so the remote backend
    /// tears down its socket here; a local open has nothing to abort.
    nonisolated func abortConnect()

    func applyBusyTimeout(_ milliseconds: Int32) async

    /// What the session has open, so nothing the app owns opens a transaction over the user's.
    /// A backend that cannot ask keeps the `.unknown` default.
    func sessionTransactionState() async -> PluginSessionTransactionState

    func executeQuery(
        _ query: String,
        parameters: [PluginCellValue]?,
        rules: SQLiteStatementRules,
        bound: SQLiteReadBound?
    ) async throws -> SQLiteRawResult
    func streamQuery(_ query: String, rules: SQLiteStatementRules, into spill: PluginRowSpill) async throws
}

// How one statement runs: the authorizer scope, and whether read-only, with `PRAGMA query_only` around it and
// `sqlite3_stmt_readonly` checked before it. Safe Mode's Read-Only keeps the session's authorizer scope, so an in-app
// read keeps the extension functions it uses; an external read takes the `.readOnly` scope, which refuses them.
nonisolated struct SQLiteStatementRules: Sendable, Equatable {
    let scope: SQLiteStatementScope
    let readsOnly: Bool

    static let unrestricted = SQLiteStatementRules(scope: .unrestricted, readsOnly: false)

    init(scope: SQLiteStatementScope, readsOnly: Bool) {
        self.scope = scope
        self.readsOnly = readsOnly || scope == .readOnly
    }

    init(_ context: PluginStatementContext) {
        if context.readOnly, context.origin == .external {
            self.init(scope: .readOnly, readsOnly: true)
        } else {
            self.init(scope: context.allowsServerCode ? .unrestricted : .noServerCode, readsOnly: context.enforcesReadOnly)
        }
    }

    // What a statement SQLite does not read as read-only is refused with, in the words of whoever asked.
    var notReadRefusal: SQLitePluginError {
        scope == .readOnly ? .readOnlyStatement : .safeModeReadOnlyStatement
    }
}

// Where a bounded read stops: once `rowCap` rows are read and another is there, or at the first row that takes the
// decoded rows past `byteLimit`. That row is kept, so the host sees its own limit was reached.
nonisolated struct SQLiteReadBound: Sendable, Equatable {
    let rowCap: Int
    let byteLimit: Int?

    init(rowCap: Int, byteLimit: Int?) {
        self.rowCap = min(max(rowCap, 1), PluginRowLimits.emergencyMax)
        self.byteLimit = byteLimit.map { max($0, 0) }
    }

    // Nil when neither bound is set, and the statement is read whole as it always was.
    static func ifSet(rowCap: Int?, byteLimit: Int?) -> SQLiteReadBound? {
        let cap = rowCap.flatMap { $0 > 0 ? $0 : nil }
        guard cap != nil || byteLimit != nil else { return nil }
        return SQLiteReadBound(rowCap: cap ?? PluginRowLimits.emergencyMax, byteLimit: byteLimit)
    }

    // Text as UTF-8, bytes as they are, null as nothing: never more than the host counts for the same row, so the read
    // never stops before the host's own budget is full.
    static func byteCount(of row: [PluginCellValue]) -> Int {
        row.reduce(0) { total, cell in
            switch cell {
            case .null: total
            case .text(let text): total + text.utf8.count
            case .bytes(let data): total + data.count
            }
        }
    }
}

/// The one thing about a running query that must be reachable while the query holds the backend
/// actor: the request to stop it. The local backend interrupts the SQLite handle; the remote
/// backend writes a cancel frame to the agent.
nonisolated protocol SQLiteCanceller: Sendable {
    func cancel()
}

extension SQLiteExecutionBackend {
    nonisolated func abortConnect() {}

    func sessionTransactionState() async -> PluginSessionTransactionState { .unknown }

    func executeQuery(_ query: String) async throws -> SQLiteRawResult {
        try await executeQuery(query, parameters: nil, rules: .unrestricted, bound: nil)
    }

    func executeParameterizedQuery(_ query: String, parameters: [PluginCellValue]) async throws -> SQLiteRawResult {
        try await executeQuery(query, parameters: parameters, rules: .unrestricted, bound: nil)
    }
}

nonisolated struct SQLiteRawResult: Sendable {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[PluginCellValue]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
    var columnOrigins: [PluginColumnOrigin?]?
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
nonisolated final class SQLiteBusyState: @unchecked Sendable {
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

nonisolated let sqliteBusyHandler: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32 = { context, retryCount in
    guard let context else { return 0 }
    let state = Unmanaged<SQLiteBusyState>.fromOpaque(context).takeUnretainedValue()
    guard state.shouldRetry(afterRetryCount: retryCount) else { return 0 }
    usleep(UInt32(SQLiteBusyState.retryIntervalMilliseconds) * 1_000)
    return 1
}

// MARK: - Local Backend

// Interrupts the local handle from Stop, behind a lock, since the interrupting thread and the actor stepping a statement
// reach it at once. SQLite forbids an interrupt on a handle that is closed or closing, so the close clears it first.
nonisolated final class SQLiteLocalCanceller: SQLiteCanceller, @unchecked Sendable {
    private let lock = NSLock()
    private let busyState: SQLiteBusyState
    private var handle: OpaquePointer?
    private var lastRead: UInt64 = 0
    private var requestRunning = false
    private var steppingRead: UInt64?
    private var interruptedDuringStep = false

    init(busyState: SQLiteBusyState) {
        self.busyState = busyState
    }

    func setHandle(_ handle: OpaquePointer?) {
        lock.withLock { self.handle = handle }
    }

    // The host's Stop for its request, sent only while one runs: a pulled read stepping before the request starts would
    // take the interrupt instead.
    func cancel() {
        lock.withLock {
            guard let handle, requestRunning else { return }
            busyState.cancel()
            sqlite3_interrupt(handle)
        }
    }

    // Ends whatever runs on the connection, a pulled read's step included, for a connection that runs one transfer.
    func cancelEverything() {
        lock.withLock {
            guard let handle else { return }
            busyState.cancel()
            if steppingRead != nil { interruptedDuringStep = true }
            sqlite3_interrupt(handle)
        }
    }

    func setRequestRunning(_ running: Bool) {
        lock.withLock { requestRunning = running }
    }

    func makeReadID() -> UInt64 {
        lock.withLock {
            lastRead &+= 1
            return lastRead
        }
    }

    // A pulled read's own Stop. Between its steps the read stops by itself at the next pull, and an interrupt then would
    // reach the next statement on the connection instead, since it stays in effect while the read's statement is open.
    func cancel(read: UInt64) {
        lock.withLock {
            guard let handle, steppingRead == read else { return }
            interruptedDuringStep = true
            busyState.cancel()
            sqlite3_interrupt(handle)
        }
    }

    func beginStep(of read: UInt64) {
        lock.withLock {
            steppingRead = read
            interruptedDuringStep = false
        }
    }

    // Whether an interrupt arrived while the step ran.
    func endStep() -> Bool {
        lock.withLock {
            defer {
                steppingRead = nil
                interruptedDuringStep = false
            }
            return interruptedDuringStep
        }
    }
}

// Opens a SQLite database with the plugin's own SQLite build on macOS, the SDK's on iOS, and runs statements against it.
actor SQLiteLocalBackend: SQLiteExecutionBackend {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLiteLocalBackend")

    private var db: OpaquePointer?
    // Kept past close: the handle points at it, and a close that SQLite refuses leaves the handle open.
    private var policy: SQLiteAuthorizerPolicy?
    private let busyState: SQLiteBusyState
    private let path: String
    private let openFlags: Int32
    nonisolated let localCanceller: SQLiteLocalCanceller
    // Statements a pulled read holds between pulls, apart from any request's, so a request never ends one.
    private var pulledReads: [UInt64: PulledRead] = [:]
    // A read whose last batch carried rows, or that had no statement: its next pull ends it.
    private var finishedReads: Set<UInt64> = []
    // A read ended under it by an interrupt another statement took.
    private var interruptedReads: Set<UInt64> = []

    nonisolated let canceller: SQLiteCanceller
    nonisolated var resolvedServerVersion: String? { String(cString: sqlite3_libversion()) }

    // The default creates a missing file, as `sqlite3_open` does. iOS opens an existing file without creating one, and a
    // transfer's reader read-only.
    init(path: String, openFlags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) {
        self.path = path
        self.openFlags = openFlags
        let busyState = SQLiteBusyState()
        self.busyState = busyState
        let canceller = SQLiteLocalCanceller(busyState: busyState)
        self.localCanceller = canceller
        self.canceller = canceller
    }

    var isConnected: Bool { db != nil }

    func open(loading extensions: [LoadableExtension]) throws {
        let expandedPath = expandPath(path)
        if openFlags & SQLITE_OPEN_CREATE != 0, !FileManager.default.fileExists(atPath: expandedPath) {
            let directory = (expandedPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        var opened: OpaquePointer?
        let result = sqlite3_open_v2(expandedPath, &opened, openFlags, nil)
        // A failed open still allocates a handle, and only a close frees it.
        guard result == SQLITE_OK, let opened else {
            let errorMessage = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            sqlite3_close(opened)
            throw SQLitePluginError.connectionFailed(errorMessage)
        }
        db = opened
        let db = opened
        let added: SQLiteExtensionNames
        do {
            if extensions.isEmpty {
                added = .empty
            } else {
                added = try SQLiteAuthorizerPolicy.extensionNames(on: db) {
                    try loadExtensions(extensions, into: db)
                }
            }
        } catch {
            close()
            throw error
        }
        if added.functions == nil || added.modules == nil {
            Self.logger.warning("SQLite did not list what the extensions added, so external statements are refused")
        }
        let policy = SQLiteAuthorizerPolicy(extensions: added)
        self.policy = policy
        SQLiteAuthorizer.install(on: db, policy: policy)
        installBusyHandler()
        localCanceller.setHandle(db)
    }

    private func loadExtensions(_ extensions: [LoadableExtension], into db: OpaquePointer) throws {
        guard !extensions.isEmpty else { return }
        #if os(iOS)
        // The SDK's SQLite has no loader, and the iOS driver never passes a list.
        throw SQLitePluginError.unsupportedOperation
        #else
        let loading = SQLiteExtensionLoading(db: db)
        try LoadableExtensionLoader.load(
            extensions,
            setLoadingEnabled: loading.setEnabled,
            loadExtension: loading.load(file:entryPoint:)
        )
        Self.logger.info("Loaded \(extensions.count, privacy: .public) SQLite extension(s)")
        #endif
    }

    // `sqlite3_close` refuses a handle with an unfinalized statement and leaves it open, so a pulled read goes first.
    func close() {
        localCanceller.setHandle(nil)
        for read in pulledReads.values {
            sqlite3_finalize(read.statement)
        }
        pulledReads.removeAll()
        finishedReads.removeAll()
        interruptedReads.removeAll()
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

    func executeQuery(
        _ query: String,
        parameters: [PluginCellValue]?,
        rules: SQLiteStatementRules,
        bound: SQLiteReadBound?
    ) throws -> SQLiteRawResult {
        try withStatementHandle(rules) { handle, notReadRefusal in
            try runStatement(query, parameters: parameters, on: handle, notReadRefusal: notReadRefusal, bound: bound)
        }
    }

    // `notReadRefusal` is set when the statement has to be one SQLite reads as read-only. A read-only statement runs on
    // the session's handle, so temporary objects, attachments, `last_insert_rowid()` and `changes()` read as they do there.
    // `isRequest` is false for a pulled read, whose steps the canceller marks one at a time.
    private func withStatementHandle<T>(
        _ rules: SQLiteStatementRules,
        isRequest: Bool = true,
        _ body: (OpaquePointer, SQLitePluginError?) throws -> T
    ) throws -> T {
        guard let db, let policy else { throw SQLitePluginError.notConnected }
        endPulledReadsUnderInterrupt(db)
        defer { endPulledReadsUnderInterrupt(db) }
        busyState.beginOperation()
        if isRequest { localCanceller.setRequestRunning(true) }
        defer { if isRequest { localCanceller.setRequestRunning(false) } }
        guard rules.readsOnly else {
            return try Self.within(rules.scope, of: policy) { try body(db, nil) }
        }
        // The pragmas run before the scope applies: the `.readOnly` scope refuses a pragma that sets anything.
        return try withQueryOnly(db) {
            try Self.within(rules.scope, of: policy) { try body(db, rules.notReadRefusal) }
        }
    }

    private static func within<T>(
        _ scope: SQLiteStatementScope,
        of policy: SQLiteAuthorizerPolicy,
        _ body: () throws -> T
    ) rethrows -> T {
        guard scope != .unrestricted else { return try body() }
        policy.scope = scope
        defer { policy.scope = .unrestricted }
        return try body()
    }

    // query_only stops writes to the database files, a write an application function makes among them. It does not stop
    // an extension's function or virtual table from reaching other files, and the `.readOnly` scope refuses those.
    private func withQueryOnly<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
        let wasQueryOnly = try Self.integerPragma("PRAGMA query_only", on: db) == 1
        if !wasQueryOnly {
            try Self.exec("PRAGMA query_only = 1", on: db)
        }
        defer {
            if !wasQueryOnly {
                // An interrupt still in effect would refuse the restore and leave the connection read-only.
                endPulledReadsUnderInterrupt(db)
                try? Self.exec("PRAGMA query_only = 0", on: db)
            }
        }
        return try body()
    }

    private static func integerPragma(_ sql: String, on db: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLitePluginError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_column_int(statement, 0)
    }

    private static func exec(_ sql: String, on db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLitePluginError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func runStatement(
        _ query: String,
        parameters: [PluginCellValue]?,
        on db: OpaquePointer,
        notReadRefusal: SQLitePluginError?,
        bound: SQLiteReadBound?
    ) throws -> SQLiteRawResult {
        let startTime = Date()
        let prepared = try Self.prepareOnlyStatement(query, db: db)
        defer { sqlite3_finalize(prepared) }
        // Text of only comments and blanks compiles to no statement, and stepping none is a misuse.
        guard let statement = prepared else {
            if let parameters, !parameters.isEmpty { throw Self.parameterCountRefusal }
            return SQLiteRawResult(
                columns: [], columnTypeNames: [], rows: [], rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime), isTruncated: false, columnOrigins: []
            )
        }
        try Self.refuseUnlessRead(statement, notReadRefusal)

        if let parameters {
            try bind(parameters, to: statement, db: db)
        }

        let totalChangesBefore = sqlite3_total_changes64(db)
        let firstStep = SQLiteResultColumns.stepFirst(statement)
        let columnCount = firstStep.count
        let columns = firstStep.names
        let columnTypeNames = firstStep.typeNames
        let columnOrigins = Self.columnOrigins(after: firstStep, of: statement, on: db, text: query)

        var rows: [[PluginCellValue]] = []
        var truncated = false
        let rowLimit = bound?.rowCap ?? PluginRowLimits.emergencyMax
        // A statement that writes runs to its end: an autocommit write commits there, and a deferred constraint it
        // breaks fails only there, so stopping early would report rows the rollback took back.
        let stopsAtLimit = sqlite3_stmt_readonly(statement) != 0
        var bytes = 0
        var stepResult = firstStep.result
        while stepResult == SQLITE_ROW {
            if !truncated, rows.count >= rowLimit {
                truncated = true
            } else if !truncated {
                let row = Self.readRow(statement, columnCount: columnCount)
                rows.append(row)
                if let byteLimit = bound?.byteLimit {
                    bytes += SQLiteReadBound.byteCount(of: row)
                    truncated = bytes > byteLimit
                }
            }
            if truncated, stopsAtLimit { break }
            stepResult = sqlite3_step(statement)
        }

        if stepResult != SQLITE_DONE, !(truncated && stopsAtLimit) {
            throw SQLitePluginError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        let rowsAffected = columns.isEmpty ? Self.changes(of: db, sinceTotal: totalChangesBefore) : 0
        return SQLiteRawResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: rowsAffected,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: truncated,
            columnOrigins: columnOrigins
        )
    }

    private static func columnOrigins(
        after firstStep: SQLiteResultColumns.FirstStep,
        of statement: OpaquePointer?,
        on db: OpaquePointer,
        text: String
    ) -> [PluginColumnOrigin?]? {
        guard firstStep.result == SQLITE_ROW || firstStep.result == SQLITE_DONE else { return nil }
        return SQLiteColumnOrigins.origins(of: statement, on: db, text: text)
    }

    // SQLite compiles only a text's first statement; a second one in the tail would be dropped without a word. The
    // tail is read, never prepared: preparing a PRAGMA already applies it.
    static func prepareOnlyStatement(_ query: String, db: OpaquePointer) throws -> OpaquePointer? {
        try query.withCString { text in
            guard !SQLiteStatementTail.pragmaHoldsSecondStatement(text) else {
                throw SQLitePluginError.queryFailed(String(localized: "Send one statement at a time."))
            }
            var statement: OpaquePointer?
            var tail: UnsafePointer<CChar>?
            guard sqlite3_prepare_v2(db, text, -1, &statement, &tail) == SQLITE_OK else {
                throw SQLitePluginError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            guard let tail, SQLiteStatementTail.holdsStatement(tail) else { return statement }
            sqlite3_finalize(statement)
            throw SQLitePluginError.queryFailed(String(localized: "Send one statement at a time."))
        }
    }

    /// `sqlite3_changes64` keeps the count of the last INSERT, UPDATE or DELETE, so a statement that
    /// wrote nothing, DDL included, would report it again. The total moves only when this one wrote.
    private static func changes(of db: OpaquePointer, sinceTotal totalBefore: Int64) -> Int {
        guard sqlite3_total_changes64(db) != totalBefore else { return 0 }
        return Int(sqlite3_changes64(db))
    }

    func streamQuery(_ query: String, rules: SQLiteStatementRules, into spill: PluginRowSpill) throws {
        try withStatementHandle(rules) { handle, notReadRefusal in
            try stream(query, on: handle, notReadRefusal: notReadRefusal, into: spill)
        }
    }

    private func stream(
        _ query: String,
        on db: OpaquePointer,
        notReadRefusal: SQLitePluginError?,
        into spill: PluginRowSpill
    ) throws {
        guard let statement = try Self.prepareOnlyStatement(query, db: db) else {
            spill.yield(PluginStreamHeader(columns: [], columnTypeNames: [], estimatedRowCount: nil))
            spill.finish()
            return
        }
        do {
            try Self.refuseUnlessRead(statement, notReadRefusal)
        } catch {
            sqlite3_finalize(statement)
            throw error
        }

        let firstStep = SQLiteResultColumns.stepFirst(statement)
        let columnCount = firstStep.count
        var header = PluginStreamHeader(
            columns: firstStep.names, columnTypeNames: firstStep.typeNames, estimatedRowCount: nil
        )
        header.columnOrigins = Self.columnOrigins(after: firstStep, of: statement, on: db, text: query)
        spill.yield(header)

        var batch = PluginRowBatcher()

        var stepResult = firstStep.result
        while stepResult == SQLITE_ROW {
            if Task.isCancelled {
                if !batch.isEmpty { spill.deliver(batch.rows) }
                sqlite3_finalize(statement)
                spill.finish(throwing: CancellationError())
                return
            }
            if batch.append(Self.readRow(statement, columnCount: columnCount)) {
                // Synchronous on the actor's thread: an await here would let another call reach the handle mid-statement.
                guard spill.deliver(batch.rows) else {
                    sqlite3_finalize(statement)
                    return
                }
                batch.removeAll()
            }
            stepResult = sqlite3_step(statement)
        }

        if !batch.isEmpty { spill.deliver(batch.rows) }

        guard stepResult == SQLITE_DONE else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(statement)
            spill.finish(throwing: SQLitePluginError.queryFailed(message))
            return
        }
        sqlite3_finalize(statement)
        spill.finish()
    }

    static let parameterCountRefusal = SQLitePluginError.queryFailed(
        String(localized: "The statement does not take the values it was given")
    )

    // EXPLAIN never runs its statement, but stmt_readonly reports that statement's writes.
    private static func refuseUnlessRead(_ statement: OpaquePointer, _ notReadRefusal: SQLitePluginError?) throws {
        if let notReadRefusal, sqlite3_stmt_readonly(statement) == 0, sqlite3_stmt_isexplain(statement) == 0 {
            throw notReadRefusal
        }
    }

    // A statement handed no values leaves its placeholders NULL; any other list binds them one for one, so a short list
    // never writes NULL where a value was left out.
    private func bind(_ parameters: [PluginCellValue], to statement: OpaquePointer?, db: OpaquePointer) throws {
        guard parameters.isEmpty || Int(sqlite3_bind_parameter_count(statement)) == parameters.count else {
            throw Self.parameterCountRefusal
        }
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, param) in parameters.enumerated() {
            let bindIndex = Int32(index + 1)
            let bindResult: Int32
            switch param {
            case .null:
                bindResult = sqlite3_bind_null(statement, bindIndex)
            case .text(let stringValue):
                bindResult = SQLiteText.bind(stringValue, to: statement, at: bindIndex)
            // An empty Data has no base address, and a null pointer binds NULL rather than an empty blob.
            case .bytes(let data) where data.isEmpty:
                bindResult = sqlite3_bind_zeroblob(statement, bindIndex, 0)
            case .bytes(let data):
                bindResult = data.withUnsafeBytes { rawBuffer -> Int32 in
                    sqlite3_bind_blob64(
                        statement, bindIndex, rawBuffer.baseAddress, sqlite3_uint64(rawBuffer.count), sqliteTransient
                    )
                }
            }
            if bindResult != SQLITE_OK {
                throw SQLitePluginError.queryFailed("Failed to bind parameter \(index): \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    private static func readRow(_ statement: OpaquePointer?, columnCount: Int32) -> [PluginCellValue] {
        (0..<columnCount).map { columnValue(statement, $0).pluginValue }
    }

    // Valid until the statement steps again. A number reads as the text SQLite prints for it.
    static func columnValue(_ statement: OpaquePointer?, _ index: Int32) -> SQLiteColumnValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_BLOB:
            // The pointer first: asking for the length first can convert the value and move it.
            let bytes = sqlite3_column_blob(statement, index)
            return .bytes(UnsafeRawBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))))
        default:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(UnsafeRawBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, index))))
        }
    }

    // MARK: - Reads that cut values

    // The rows of one statement, each value made by `read` from SQLite's own buffer and handed to `deliver` a batch at a
    // time, until `rowLimit` rows are read or `deliver` declines. The statement ends inside this call, so nothing stays
    // open on the connection after it. Rows read before a failure are delivered before it is thrown. Returns the rows a
    // statement with no columns changed. A caller cancelled while it waited for the connection runs nothing.
    func readValues<Value: Sendable>(
        _ query: String,
        rules: SQLiteStatementRules,
        rowLimit: Int,
        reading read: SQLiteValueReader<Value>,
        header: @Sendable (PluginStreamHeader) -> Void,
        deliver: @Sendable ([[Value]]) -> Bool
    ) throws -> Int {
        try Task.checkCancellation()
        return try withStatementHandle(rules) { db, notReadRefusal in
            guard let statement = try Self.prepareOnlyStatement(query, db: db) else {
                header(PluginStreamHeader(columns: [], columnTypeNames: [], estimatedRowCount: nil))
                return 0
            }
            defer { sqlite3_finalize(statement) }
            try Self.refuseUnlessRead(statement, notReadRefusal)
            let totalChangesBefore = sqlite3_total_changes64(db)
            let first = SQLiteResultColumns.stepFirst(statement)
            header(PluginStreamHeader(columns: first.names, columnTypeNames: first.typeNames, estimatedRowCount: nil))
            var batch: [[Value]] = []
            var count = 0
            var step = first.result
            while step == SQLITE_ROW, count < rowLimit {
                if Task.isCancelled {
                    if !batch.isEmpty { _ = deliver(batch) }
                    throw CancellationError()
                }
                batch.append(first.names.indices.map { read(first.names[$0], Self.columnValue(statement, Int32($0))) })
                count += 1
                if batch.count >= Self.pulledBatchSize {
                    guard deliver(batch) else { return 0 }
                    batch.removeAll(keepingCapacity: true)
                }
                // A step past the limit would compute a row nobody reads.
                guard count < rowLimit else { break }
                step = sqlite3_step(statement)
            }
            if !batch.isEmpty, !deliver(batch) { return 0 }
            guard step == SQLITE_ROW || step == SQLITE_DONE else {
                throw SQLitePluginError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            return first.names.isEmpty ? Self.changes(of: db, sinceTotal: totalChangesBefore) : 0
        }
    }

    // MARK: - Pulled reads

    static let pulledBatchSize = 500

    private struct PulledRead {
        let statement: OpaquePointer
        let columnCount: Int32
        let rules: SQLiteStatementRules
        // The last step's result; on SQLITE_ROW the row it stands on is not read yet.
        var step: Int32
    }

    // The statement is prepared and stepped once here, so the header names the columns the rows will have.
    func beginPulledRead(_ id: UInt64, query: String, rules: SQLiteStatementRules) throws -> PluginStreamHeader {
        try Task.checkCancellation()
        return try withStatementHandle(rules, isRequest: false) { db, notReadRefusal in
            guard let statement = try Self.prepareOnlyStatement(query, db: db) else {
                finishedReads.insert(id)
                return PluginStreamHeader(columns: [], columnTypeNames: [], estimatedRowCount: nil)
            }
            let first: SQLiteResultColumns.FirstStep
            do {
                try Self.refuseUnlessRead(statement, notReadRefusal)
                first = try stepping(id) { SQLiteResultColumns.stepFirst(statement) }
            } catch {
                sqlite3_finalize(statement)
                throw error
            }
            guard first.result == SQLITE_ROW || first.result == SQLITE_DONE else {
                let message = String(cString: sqlite3_errmsg(db))
                sqlite3_finalize(statement)
                throw SQLitePluginError.queryFailed(message)
            }
            pulledReads[id] = PulledRead(statement: statement, columnCount: first.count, rules: rules, step: first.result)
            return PluginStreamHeader(columns: first.names, columnTypeNames: first.typeNames, estimatedRowCount: nil)
        }
    }

    // Nil once the read has no rows left, its statement then finalized.
    func nextPulledBatch(_ id: UInt64) throws -> [[PluginCellValue]]? {
        try withStatementHandle(.unrestricted, isRequest: false) { db, _ in
            if interruptedReads.remove(id) != nil {
                throw SQLitePluginError.queryFailed(String(cString: sqlite3_errstr(SQLITE_INTERRUPT)))
            }
            guard var read = pulledReads[id] else {
                if finishedReads.remove(id) != nil { return nil }
                throw CancellationError()
            }
            return try applying(read.rules) {
                var rows: [[PluginCellValue]] = []
                while read.step == SQLITE_ROW, rows.count < Self.pulledBatchSize {
                    rows.append(Self.readRow(read.statement, columnCount: read.columnCount))
                    let statement = read.statement
                    do {
                        read.step = try stepping(id) { sqlite3_step(statement) }
                    } catch {
                        endPulledRead(id)
                        throw error
                    }
                }
                switch read.step {
                case SQLITE_ROW:
                    pulledReads[id] = read
                    return rows
                case SQLITE_DONE:
                    endPulledRead(id)
                    guard !rows.isEmpty else { return nil }
                    finishedReads.insert(id)
                    return rows
                default:
                    let message = String(cString: sqlite3_errmsg(db))
                    endPulledRead(id)
                    throw SQLitePluginError.queryFailed(message)
                }
            }
        }
    }

    func endPulledRead(_ id: UInt64) {
        finishedReads.remove(id)
        interruptedReads.remove(id)
        guard let read = pulledReads.removeValue(forKey: id) else { return }
        sqlite3_finalize(read.statement)
    }

    // The read's own rules around a pull: its query_only and authorizer scope, applied for each batch it steps.
    private func applying<T>(_ rules: SQLiteStatementRules, _ body: () throws -> T) throws -> T {
        guard rules != .unrestricted, let db, let policy else { return try body() }
        guard rules.readsOnly else { return try Self.within(rules.scope, of: policy, body) }
        return try withQueryOnly(db) { try Self.within(rules.scope, of: policy, body) }
    }

    // Marks the step before reading the cancel, so a consumer that leaves at any moment is either seen here or finds its
    // read stepping and interrupts it.
    private func stepping<T>(_ id: UInt64, _ step: () -> T) throws -> T {
        localCanceller.beginStep(of: id)
        guard !Task.isCancelled else {
            _ = localCanceller.endStep()
            throw CancellationError()
        }
        let result = step()
        guard !localCanceller.endStep() else { throw CancellationError() }
        return result
    }

    // An interrupt stays in effect while any statement on the connection is unfinished, so once one is in effect every
    // read left open between pulls ends: each would fail at its next step, and so would the next statement beside it, a
    // write inside the user's transaction rolling that transaction back.
    private func endPulledReadsUnderInterrupt(_ db: OpaquePointer) {
        guard !pulledReads.isEmpty, sqlite3_is_interrupted(db) != 0 else { return }
        for (id, read) in pulledReads {
            sqlite3_finalize(read.statement)
            interruptedReads.insert(id)
        }
        pulledReads.removeAll()
    }
}

// A value as SQLite holds it for the row a statement stands on.
nonisolated enum SQLiteColumnValue {
    case null
    case text(UnsafeRawBufferPointer)
    case bytes(UnsafeRawBufferPointer)

    var pluginValue: PluginCellValue {
        switch self {
        case .null: .null
        case .text(let utf8): .text(String(decoding: utf8, as: UTF8.self))
        case .bytes(let bytes): .bytes(Data(bytes))
        }
    }
}

// What a read hands out for a value of the named column.
typealias SQLiteValueReader<Value> = @Sendable (_ column: String, _ value: SQLiteColumnValue) -> Value
