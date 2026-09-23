//
//  LibPQPluginConnection.swift
//  PostgreSQLDriverPlugin
//
//  Swift wrapper around libpq (PostgreSQL C API)
//  Provides thread-safe, async-friendly PostgreSQL connections.
//  Adapted from TablePro's LibPQConnection for the plugin architecture.
//

import CLibPQ
import Foundation
import os
import OSLog
import TableProPluginKit

// MARK: - Connection Class

/// libpq allows one thread at a time on a `PGconn`, so every libpq call on `conn` runs on `queue`,
/// and a member that other files can reach and that makes such a call opens with
/// `preconditionOnQueue()`. `stateLock` guards `conn`, `serverMessages` and the underscored state,
/// is never held across a libpq call, and is taken in this file only. Cancelling a running query
/// is the one path that calls libpq off the queue.
final class LibPQPluginConnection: @unchecked Sendable {
    static let logger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "LibPQPluginConnection")

    private static let connectTimeoutMicroseconds: pg_usec_time_t = 10_000_000
    private static let pollSliceMicroseconds: pg_usec_time_t = 100_000

    private var conn: OpaquePointer?
    private let queue = DispatchQueue(label: "com.TablePro.libpq.plugin", qos: .userInitiated)

    private let host: String
    private let port: Int
    private let user: String
    private let password: String?
    private let database: String
    private let sslConfig: SSLConfiguration
    private let options: String?
    private let suppressServerSideCancel: Bool

    private let stateLock = NSLock()
    let cancellationGate = PluginQueryCancellationGate()
    let typeNames = LibPQTypeNameRegistry()
    private var _isConnected: Bool = false
    private var _isShuttingDown: Bool = false
    private var _cachedServerVersion: String?
    private var _cachedServerVersionNumber: Int32 = 0
    private var _isConnectCancelled: Bool = false
    private var _lastTransactionState: LibPQTransactionState = .idle
    private var _hasLostConnection = false
    private var serverMessages: Unmanaged<LibPQServerMessageSink>?
    private var _standardConformingStrings = true

    var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isConnected
    }

    var standardConformingStrings: Bool {
        stateLock.withLock { _standardConformingStrings }
    }

    private var isShuttingDown: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isShuttingDown
        }
        set {
            stateLock.lock()
            _isShuttingDown = newValue
            stateLock.unlock()
        }
    }

    var connectionHandle: OpaquePointer? {
        preconditionOnQueue()
        return stateLock.withLock { conn }
    }

    func preconditionOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    init(
        host: String,
        port: Int,
        user: String,
        password: String?,
        database: String,
        sslConfig: SSLConfiguration = SSLConfiguration(),
        options: String? = nil,
        suppressServerSideCancel: Bool = false
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.sslConfig = sslConfig
        self.options = options
        self.suppressServerSideCancel = suppressServerSideCancel
    }

    deinit {
        let handle = conn
        let sink = serverMessages
        let cleanupQueue = queue
        conn = nil
        serverMessages = nil
        if let handle = handle {
            cleanupQueue.async {
                PQfinish(handle)
                sink?.release()
            }
        }
    }

    // MARK: - Connection Management

    func connect(reportingStage report: @escaping ConnectionStageReporter = { _ in }) async throws {
        stateLock.withLock { _isConnectCancelled = false }

        try await withTaskCancellationHandler {
            try await pluginDispatchAsyncCancellable(
                on: queue,
                cancellationCheck: { [weak self] in self?.isConnectCancelled ?? true }
            ) { [self] in
                try performConnect(reportingStage: report)
            }
        } onCancel: {
            cancelConnect()
        }
    }

    func cancelConnect() {
        stateLock.lock()
        _isConnectCancelled = true
        stateLock.unlock()
    }

    private var isConnectCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isConnectCancelled
    }

    private func performConnect(reportingStage report: @escaping ConnectionStageReporter) throws {
        guard let connection = connectionString.withCString({ PQconnectStart($0) }) else {
            throw LibPQPluginError.connectionFailed
        }

        var adopted = false
        defer {
            if !adopted { PQfinish(connection) }
        }

        guard PQstatus(connection) != CONNECTION_BAD else {
            throw connectionError(from: connection)
        }

        try pollUntilConnected(connection, reportingStage: report)
        configureEstablishedConnection(connection)
        let sink = LibPQServerMessageSink.install(on: connection)

        stateLock.lock()
        conn = connection
        serverMessages = sink
        _lastTransactionState = .idle
        _hasLostConnection = false
        _isConnected = true
        stateLock.unlock()
        adopted = true
    }

    private func pollUntilConnected(
        _ connection: OpaquePointer,
        reportingStage report: @escaping ConnectionStageReporter
    ) throws {
        let deadline = PQgetCurrentTimeUSec() + Self.connectTimeoutMicroseconds
        var status = PGRES_POLLING_WRITING
        var lastHandshakeStatus: ConnStatusType?

        while true {
            try checkConnectCancellation()
            reportHandshakeStage(of: connection, last: &lastHandshakeStatus, report: report)

            switch status {
            case PGRES_POLLING_OK:
                return
            case PGRES_POLLING_FAILED:
                throw connectionError(from: connection)
            case PGRES_POLLING_READING, PGRES_POLLING_WRITING:
                let socket = PQsocket(connection)
                guard socket >= 0 else { throw connectionError(from: connection) }

                let now = PQgetCurrentTimeUSec()
                guard now < deadline else { throw LibPQPluginError.connectionTimedOut }

                let ready = PQsocketPoll(
                    socket,
                    status == PGRES_POLLING_READING ? 1 : 0,
                    status == PGRES_POLLING_WRITING ? 1 : 0,
                    min(deadline, now + Self.pollSliceMicroseconds)
                )
                guard ready >= 0 else { throw LibPQPluginError.connectionFailed }
                guard ready > 0 else { continue }

                status = PQconnectPoll(connection)
            default:
                status = PQconnectPoll(connection)
            }
        }
    }

    /// `PGRES_POLLING_*` only says whether the socket wants a read or a write, so it cannot tell
    /// a TLS handshake from an authentication exchange. `PQstatus` can, and reading it costs one
    /// pointer dereference per poll slice.
    private func reportHandshakeStage(
        of connection: OpaquePointer,
        last: inout ConnStatusType?,
        report: ConnectionStageReporter
    ) {
        let current = PQstatus(connection)
        guard current != last else { return }
        last = current

        switch current {
        case CONNECTION_SSL_STARTUP:
            report(.negotiatingEncryption)
        case CONNECTION_AWAITING_RESPONSE, CONNECTION_AUTH_OK:
            report(.authenticating)
        default:
            break
        }
    }

    private func checkConnectCancellation() throws {
        guard isConnectCancelled else { return }
        throw CancellationError()
    }

    private func connectionError(from connection: OpaquePointer) -> Error {
        let error = getError(from: connection)
        if let sslError = LibPQSSLClassifier.classifySSLError(error.message) {
            return sslError
        }
        return error
    }

    private func configureEstablishedConnection(_ connection: OpaquePointer) {
        logUnexpectedClientEncoding(of: connection)
        runSessionSetupStatement(LibPQStringConformance.enableStatement, on: connection)
        storeStandardConformingStrings(
            reportedStandardConformingStrings(on: connection)
                ?? queriedStandardConformingStrings(on: connection)
                ?? true
        )

        let version = PQserverVersion(connection)
        guard version > 0 else { return }

        let major = version / 10_000
        let displayVersion: String
        if major >= 10 {
            let minor = version % 10_000
            displayVersion = "\(major).\(minor)"
        } else {
            let minor = (version / 100) % 100
            let revision = version % 100
            displayVersion = "\(major).\(minor).\(revision)"
        }

        stateLock.withLock {
            _cachedServerVersionNumber = version
            _cachedServerVersion = displayVersion
        }
    }

    private func logUnexpectedClientEncoding(of connection: OpaquePointer) {
        let reported = PQparameterStatus(connection, "client_encoding").map { String(cString: $0) }
        guard !LibPQConnectionString.isClientEncoding(reportedByServer: reported) else { return }
        Self.logger.warning(
            "Server reports client_encoding \(reported ?? "none", privacy: .public) instead of UTF8"
        )
    }

    private func runSessionSetupStatement(_ statement: String, on connection: OpaquePointer) {
        let result = statement.withCString { PQexec(connection, $0) }
        defer { PQclear(result) }
        guard PQresultStatus(result) != PGRES_COMMAND_OK else { return }
        let message = result.flatMap { PQresultErrorMessage($0) }.map { String(cString: $0) } ?? ""
        Self.logger.warning(
            "Session setup statement failed: \(statement, privacy: .public) \(message, privacy: .private)"
        )
    }

    private func reportedStandardConformingStrings(on connection: OpaquePointer) -> Bool? {
        guard let value = PQparameterStatus(connection, LibPQStringConformance.parameterName) else {
            return nil
        }
        return LibPQStringConformance.isOn(String(cString: value))
    }

    private func queriedStandardConformingStrings(on connection: OpaquePointer) -> Bool? {
        let result = LibPQStringConformance.showQuery.withCString { PQexec(connection, $0) }
        defer { PQclear(result) }
        guard PQresultStatus(result) == PGRES_TUPLES_OK,
              PQntuples(result) > 0,
              let value = PQgetvalue(result, 0, 0) else {
            return nil
        }
        return LibPQStringConformance.isOn(String(cString: value))
    }

    private func refreshStandardConformingStrings(from connection: OpaquePointer) {
        guard let reported = reportedStandardConformingStrings(on: connection) else { return }
        storeStandardConformingStrings(reported)
    }

    private func storeStandardConformingStrings(_ value: Bool) {
        let changed = stateLock.withLock {
            defer { _standardConformingStrings = value }
            return _standardConformingStrings != value
        }
        guard changed, !value else { return }
        Self.logger.warning("standard_conforming_strings is off; string literals escape backslashes")
    }

    private var connectionString: String {
        LibPQConnectionString.build(
            host: host,
            port: port,
            user: user,
            password: password,
            database: database,
            sslConfig: sslConfig,
            options: options
        )
    }

    func disconnect() {
        isShuttingDown = true

        stateLock.lock()
        _isConnected = false
        _isConnectCancelled = true
        let handle = conn
        let sink = serverMessages
        conn = nil
        serverMessages = nil
        _cachedServerVersion = nil
        _cachedServerVersionNumber = 0
        stateLock.unlock()

        if let handle {
            queue.async {
                PQfinish(handle)
                sink?.release()
            }
        }
    }

    // MARK: - Catalog Type Names

    func setPostgisOidMap(_ map: [UInt32: PostGISType]) {
        typeNames.setPostgisTypes(map)
    }

    func mergeCatalogTypeNames(_ names: [UInt32: String]) {
        typeNames.merge(names)
    }

    // MARK: - Query Cancellation

    func cancelCurrentQuery() {
        guard cancellationGate.cancel() != nil else { return }

        stateLock.lock()
        let currentConn = conn
        stateLock.unlock()

        guard let currentConn, !suppressServerSideCancel else { return }
        let cancelObj = PQgetCancel(currentConn)
        guard let cancelObj else { return }
        defer { PQfreeCancel(cancelObj) }

        var errbuf = [CChar](repeating: 0, count: 256)
        PQcancel(cancelObj, &errbuf, Int32(errbuf.count))
    }

    // MARK: - Query Execution

    func executeQuery(_ query: String) async throws -> LibPQPluginQueryResult {
        let queryToRun = String(query)

        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown else { throw LibPQPluginError.notConnected }
            return try executeQuerySync(queryToRun)
        }
    }

    /// Runs a read whose statement changes session settings with `SET LOCAL`, and confines those
    /// settings to the read whether or not the session has a transaction block open.
    ///
    /// With no block open, the settings and the read are one implicit transaction that ends with it.
    /// Inside a block they would outlast the read, so a savepoint scopes them and is rolled back
    /// straight after. The status check and every statement run in one block on this connection's
    /// queue. Split into separate dispatches, another caller sharing the session could run between
    /// the savepoint and its rollback, and the rollback silently undid that caller's work. PGlite has
    /// no pooled connection, so a query tab and the metadata reads share one session.
    ///
    /// The `ROLLBACK TO` is its own `PQexec`, because `PQexec` returns only a string's last result
    /// and the rows are the read's. A rollback that fails after a read that succeeded is reported
    /// rather than the rows: the session would otherwise keep the read's settings for the rest of
    /// the user's transaction.
    func executeTransactionScopedRead(_ statement: String) async throws -> LibPQPluginQueryResult {
        let statementToRun = String(statement)

        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown else { throw LibPQPluginError.notConnected }
            guard isInsideTransactionBlockOnQueue() else {
                return try executeQuerySync(statementToRun)
            }
            _ = try executeQuerySync(Self.scopedReadSavepoint)
            let result: LibPQPluginQueryResult
            do {
                result = try executeQuerySync(statementToRun)
            } catch {
                _ = try? executeQuerySync(Self.scopedReadRollback)
                throw error
            }
            _ = try executeQuerySync(Self.scopedReadRollback)
            return result
        }
    }

    private static let scopedReadSavepoint = "SAVEPOINT tablepro_scoped_read"
    private static let scopedReadRollback = "ROLLBACK TO SAVEPOINT tablepro_scoped_read; RELEASE SAVEPOINT tablepro_scoped_read"

    /// Whether the session is inside a transaction block, including one a failed statement has
    /// aborted, so a statement sent now joins it. Called on the connection's queue only: one `PGconn`
    /// may not be used from two threads at once, and the lock guards the pointer rather than the call.
    private func isInsideTransactionBlockOnQueue() -> Bool {
        let state = transactionStateOnQueue()
        return state == .inTransaction || state == .inError
    }

    /// What the session has open, from the `ReadyForQuery` status libpq keeps from the last reply.
    ///
    /// No round trip and no server work: measured against PostgreSQL 17.11, a million calls took
    /// 1.5ms, and the answer is local enough to survive a backend another session terminated
    /// (`PQtransactionStatus` still reported `INTRANS` with `PQstatus` OK).
    func transactionState() async -> LibPQTransactionState {
        do {
            return try await pluginDispatchAsync(on: queue) { [self] in
                guard !isShuttingDown else { return LibPQTransactionState.unknown }
                return transactionStateOnQueue()
            }
        } catch {
            return .unknown
        }
    }

    private func transactionStateOnQueue() -> LibPQTransactionState {
        guard let conn = connectionHandle, PQstatus(conn) == CONNECTION_OK else { return .unknown }
        return Self.transactionState(PQtransactionStatus(conn))
    }

    func boundedQuery(_ query: String, rowCap: Int) async throws -> LibPQPluginQueryResult {
        let queryToRun = String(query)
        let cap = max(rowCap, 1)

        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown else { throw LibPQPluginError.notConnected }
            return try boundedQuerySync(queryToRun, rowCap: cap)
        }
    }

    func executeParameterizedQuery(_ query: String, parameters: [PluginCellValue]) async throws -> LibPQPluginQueryResult {
        let queryToRun = String(query)
        let params = parameters

        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown else { throw LibPQPluginError.notConnected }
            return try executeParameterizedQuerySync(queryToRun, parameters: params)
        }
    }

    // MARK: - Server Information

    func serverVersion() -> String? {
        stateLock.withLock { _cachedServerVersion }
    }

    func serverVersionNumber() -> Int32 {
        stateLock.withLock { _cachedServerVersionNumber }
    }

    func currentDatabase() -> String {
        database
    }

    // MARK: - Synchronous Query Execution

    private func executeQuerySync(_ query: String) throws -> LibPQPluginQueryResult {
        let conn = connectionHandle

        guard !isShuttingDown, let conn else {
            throw LibPQPluginError.notConnected
        }

        let generation = cancellationGate.beginQuery()
        defer { cancellationGate.endQuery(generation) }
        defer { refreshStandardConformingStrings(from: conn) }

        let cancelsOutput = cancelsAbandonedOutput(conn)
        if let ended = sessionEndedBeforeSending(conn) { throw ended }

        let localQuery = String(query)
        let result: OpaquePointer? = localQuery.withCString { queryPtr in
            PQexec(conn, queryPtr)
        }

        guard let result = result else {
            throw lostConnection(getError(from: conn), on: conn, sent: true)
        }
        recordTransactionState(of: conn)

        let status = PQresultStatus(result)

        switch status {
        case PGRES_COMMAND_OK:
            let affected = getAffectedRows(from: result)
            let cmdTag = getCommandTag(from: result)
            PQclear(result)
            noteCommandTag(cmdTag, conn: conn)
            return LibPQPluginQueryResult(
                columns: [],
                columnOids: [],
                columnTypeNames: [],
                rows: [],
                affectedRows: affected,
                commandTag: cmdTag,
                isTruncated: false
            )

        case PGRES_TUPLES_OK:
            defer { PQclear(result) }
            return try fetchResults(from: result, conn: conn, generation: generation)

        default:
            if let copy = LibPQCopyState.copy(of: result) {
                PQclear(result)
                throw abandonedCopyError(copy, conn: conn, cancellingOutput: cancelsOutput, generation: generation)
            }
            let error = getResultError(from: result)
            PQclear(result)
            if cancellationGate.isCancelled(generation) { throw CancellationError() }
            throw lostConnection(error, on: conn, sent: true)
        }
    }

    /// Reads at most `rowCap` rows through libpq's single-row mode, then cancels the statement and
    /// drains the connection instead of pulling the rest of the result across the socket.
    ///
    /// One row past the cap is read so `isTruncated` can tell "exactly `rowCap` rows" from "more
    /// rows exist". The cancel is not an optimization: libpq drains an abandoned result inside the
    /// next `PQexec`, charging that cost to the user's next statement, and the backend stays active
    /// holding its snapshot until it can finish writing to the client.
    private func boundedQuerySync(_ query: String, rowCap: Int) throws -> LibPQPluginQueryResult {
        let conn = connectionHandle

        guard !isShuttingDown, let conn else {
            throw LibPQPluginError.notConnected
        }

        let generation = cancellationGate.beginQuery()
        defer { cancellationGate.endQuery(generation) }
        defer { refreshStandardConformingStrings(from: conn) }

        /// Started before the drain, so a result the previous statement abandoned is charged to the
        /// time before the first row rather than appearing as this query's row transfer.
        let sentAt = Date()

        /// Cancelling a statement inside a transaction block puts the transaction into the aborted
        /// state, and every later command fails until ROLLBACK. Reading the tail of one result costs
        /// less than throwing away the transaction the user opened, so the cancel is withheld here
        /// and the connection is drained instead.
        let cancelsOutput = cancelsAbandonedOutput(conn)
        let suppressCancel = !cancelsOutput
        _ = finishPendingResults(conn, cancellingOutput: cancelsOutput)
        if let ended = sessionEndedBeforeSending(conn) { throw ended }

        let localQuery = String(query)
        let sendOk = localQuery.withCString { queryPtr in
            PQsendQuery(conn, queryPtr)
        }
        guard sendOk != 0 else {
            throw lostConnection(getError(from: conn), on: conn, sent: false)
        }

        guard PQsetSingleRowMode(conn) != 0 else {
            _ = cancelAndDrain(conn, suppressCancel: suppressCancel)
            throw LibPQPluginError(message: "Failed to enter single-row mode", sqlState: nil, detail: nil)
        }

        var metadata: ColumnMetadata?
        var rows: [[PluginCellValue]] = []
        rows.reserveCapacity(min(rowCap, 10_000))
        var affectedRows = 0
        var commandTag: String?
        var truncated = false
        var pendingError: Error?
        var firstRowTime: TimeInterval?
        var failedStatement: LibPQPluginError?

        while let result = PQgetResult(conn) {
            let status = PQresultStatus(result)
            if firstRowTime == nil { firstRowTime = Date().timeIntervalSince(sentAt) }

            if status == PGRES_SINGLE_TUPLE {
                let columns = metadata ?? readColumnMetadata(from: result)
                metadata = columns

                var row: [PluginCellValue] = []
                row.reserveCapacity(columns.columnOids.count)
                for columnIndex in columns.columnOids.indices {
                    row.append(Self.decodeCell(
                        from: result,
                        row: 0,
                        column: Int32(columnIndex),
                        oid: columns.columnOids[columnIndex]
                    ))
                }
                PQclear(result)
                rows.append(row)

                if cancellationGate.isCancelled(generation) {
                    _ = cancelAndDrain(conn, suppressCancel: suppressCancel)
                    throw CancellationError()
                }
                if rows.count > rowCap {
                    truncated = true
                    break
                }
                continue
            }

            if status == PGRES_TUPLES_OK {
                if metadata == nil { metadata = readColumnMetadata(from: result) }
                PQclear(result)
                continue
            }

            if status == PGRES_COMMAND_OK {
                affectedRows = getAffectedRows(from: result)
                commandTag = getCommandTag(from: result)
                PQclear(result)
                continue
            }

            if let copy = LibPQCopyState.copy(of: result) {
                pendingError = Self.unsupportedCopyError(copy)
                PQclear(result)
                break
            }

            failedStatement = getResultError(from: result)
            PQclear(result)
            break
        }

        let outcome = truncated
            ? cancelAndDrain(conn, suppressCancel: suppressCancel)
            : finishPendingResults(conn, cancellingOutput: cancelsOutput)
        recordTransactionState(of: conn)

        if let failedStatement {
            if cancellationGate.isCancelled(generation) { throw CancellationError() }
            throw lostConnection(failedStatement, on: conn, sent: true)
        }
        if let pendingError {
            if cancellationGate.isCancelled(generation) { throw CancellationError() }
            throw pendingError
        }
        if cancellationGate.isCancelled(generation) { throw CancellationError() }
        if let abandoned = abandonedCopyError(outcome, generation: generation) { throw abandoned }

        if truncated { rows.removeLast() }

        noteCommandTag(commandTag, conn: conn)
        let resolvedMetadata = metadata.map { resolvingUnknownTypes($0, conn: conn) }
        let bounded = LibPQPluginQueryResult(
            columns: resolvedMetadata?.columns ?? [],
            columnOids: resolvedMetadata?.columnOids ?? [],
            columnTypeNames: resolvedMetadata?.columnTypeNames ?? [],
            rows: rows,
            affectedRows: affectedRows,
            commandTag: commandTag,
            isTruncated: truncated,
            firstRowTime: firstRowTime ?? Date().timeIntervalSince(sentAt)
        )
        return applySpatialRendering(to: bounded)
    }

    private func executeParameterizedQuerySync(_ query: String, parameters: [PluginCellValue]) throws -> LibPQPluginQueryResult {
        let conn = connectionHandle

        guard !isShuttingDown, let conn else {
            throw LibPQPluginError.notConnected
        }

        let generation = cancellationGate.beginQuery()
        defer { cancellationGate.endQuery(generation) }
        defer { refreshStandardConformingStrings(from: conn) }

        let cancelsOutput = cancelsAbandonedOutput(conn)
        var paramValues: [UnsafePointer<CChar>?] = []
        var paramLengths: [Int32] = []
        var paramFormats: [Int32] = []
        var allocations: [UnsafeMutableRawPointer] = []

        defer {
            for ptr in allocations {
                free(ptr)
            }
        }

        paramValues.reserveCapacity(parameters.count)
        paramLengths.reserveCapacity(parameters.count)
        paramFormats.reserveCapacity(parameters.count)

        for param in parameters {
            switch param {
            case .null:
                paramValues.append(nil)
                paramLengths.append(0)
                paramFormats.append(0)
            case .text(let str):
                guard let cStr = strdup(str) else {
                    throw LibPQPluginError(message: "Failed to allocate parameter buffer", sqlState: nil, detail: nil)
                }
                allocations.append(UnsafeMutableRawPointer(cStr))
                paramValues.append(UnsafePointer(cStr))
                paramLengths.append(0)
                paramFormats.append(0)
            case .bytes(let data):
                let byteCount = data.count
                guard let raw = malloc(max(byteCount, 1)) else {
                    throw LibPQPluginError(message: "Failed to allocate parameter buffer", sqlState: nil, detail: nil)
                }
                allocations.append(raw)
                if byteCount > 0 {
                    data.copyBytes(to: raw.assumingMemoryBound(to: UInt8.self), count: byteCount)
                }
                paramValues.append(UnsafePointer(raw.assumingMemoryBound(to: CChar.self)))
                paramLengths.append(Int32(byteCount))
                paramFormats.append(1)
            }
        }

        if let ended = sessionEndedBeforeSending(conn) { throw ended }

        let localQuery = String(query)
        let result: OpaquePointer? = localQuery.withCString { queryPtr in
            paramLengths.withUnsafeBufferPointer { lengthsBuf in
                paramFormats.withUnsafeBufferPointer { formatsBuf in
                    PQexecParams(
                        conn,
                        queryPtr,
                        Int32(parameters.count),
                        nil,
                        paramValues,
                        lengthsBuf.baseAddress,
                        formatsBuf.baseAddress,
                        0
                    )
                }
            }
        }

        guard let result = result else {
            throw lostConnection(getError(from: conn), on: conn, sent: true)
        }
        recordTransactionState(of: conn)

        let status = PQresultStatus(result)

        switch status {
        case PGRES_COMMAND_OK:
            let affected = getAffectedRows(from: result)
            let cmdTag = getCommandTag(from: result)
            PQclear(result)
            noteCommandTag(cmdTag, conn: conn)
            return LibPQPluginQueryResult(
                columns: [],
                columnOids: [],
                columnTypeNames: [],
                rows: [],
                affectedRows: affected,
                commandTag: cmdTag,
                isTruncated: false
            )

        case PGRES_TUPLES_OK:
            defer { PQclear(result) }
            return try fetchResults(from: result, conn: conn, generation: generation)

        default:
            if let copy = LibPQCopyState.copy(of: result) {
                PQclear(result)
                throw abandonedCopyError(copy, conn: conn, cancellingOutput: cancelsOutput, generation: generation)
            }
            let error = getResultError(from: result)
            PQclear(result)
            if cancellationGate.isCancelled(generation) { throw CancellationError() }
            throw lostConnection(error, on: conn, sent: true)
        }
    }

    // MARK: - Pending Results

    /// A statement the user did not get to see is worse than a slow one, so a COPY ended by any
    /// drain is reported rather than swallowed: `INSERT INTO t VALUES (1); COPY t FROM STDIN` used
    /// to come back as "INSERT 0 1" with the COPY discarded.
    private func abandonedCopyError(_ outcome: LibPQDrainOutcome, generation: Int) -> Error? {
        guard let copy = outcome.abandonedCopy else { return nil }
        if cancellationGate.isCancelled(generation) { return CancellationError() }
        return Self.unsupportedCopyError(copy)
    }

    private func abandonedCopyError(
        _ copy: LibPQCopy,
        conn: OpaquePointer,
        cancellingOutput: Bool,
        generation: Int
    ) -> Error {
        _ = finishPendingResults(conn, cancellingOutput: cancellingOutput)
        if cancellationGate.isCancelled(generation) { return CancellationError() }
        return Self.unsupportedCopyError(copy)
    }

    private static func unsupportedCopyError(_ copy: LibPQCopy) -> LibPQPluginError {
        LibPQPluginError(message: copy.direction.unsupportedMessage, sqlState: nil, detail: nil)
    }

    /// Reading `COPY TO STDOUT` to its end defeats the row cap the bounded read exists for, so the
    /// statement is cancelled first wherever a cancel is safe. Inside a transaction block it is not,
    /// because a cancel aborts the transaction the user opened.
    private func cancelsAbandonedOutput(_ conn: OpaquePointer) -> Bool {
        !suppressServerSideCancel && PQtransactionStatus(conn) != PQTRANS_INTRANS
    }

    private func finishPendingResults(_ conn: OpaquePointer, cancellingOutput: Bool) -> LibPQDrainOutcome {
        let outcome = LibPQCopyState.finishPendingResults(conn, cancellingOutput: cancellingOutput)
        guard let stuck = outcome.stuckInCopy else { return outcome }
        Self.logger.fault(
            "libpq stayed in \(String(describing: stuck.direction), privacy: .public); dropping the connection"
        )
        stateLock.withLock { _hasLostConnection = true }
        disconnect()
        return outcome
    }

    // MARK: - Streaming Query

    private func cancelAndDrain(_ conn: OpaquePointer, suppressCancel: Bool) -> LibPQDrainOutcome {
        if !suppressCancel {
            let cancelObj = PQgetCancel(conn)
            if let cancelObj {
                var errbuf = [CChar](repeating: 0, count: 256)
                PQcancel(cancelObj, &errbuf, Int32(errbuf.count))
                PQfreeCancel(cancelObj)
            }
        }
        return finishPendingResults(conn, cancellingOutput: false)
    }

    /// The abort is polled by the producer rather than acted on from `onTermination`, because both
    /// run on one serial queue: a drain enqueued from the handler sits behind the producer and runs
    /// only once the whole result has been read, which is no abort at all.
    func streamQuery(_ query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let queryToRun = String(query)

        return PluginRowStream.make { continuation, abort in
            self.queue.async { [self] in
                let handle = connectionHandle

                guard !isShuttingDown, let conn = handle else {
                    continuation.finish(throwing: LibPQPluginError.notConnected)
                    return
                }

                let generation = cancellationGate.beginQuery()
                defer { cancellationGate.endQuery(generation) }
                defer { refreshStandardConformingStrings(from: conn) }

                /// The consumer can go away before this block is scheduled, in which case the
                /// query is never sent at all.
                guard !abort.isAborted else {
                    continuation.finish()
                    return
                }

                /// Read before the query goes out: once it is in flight the status is
                /// PQTRANS_ACTIVE, and the transaction this guard exists for is invisible.
                let cancelsOutput = cancelsAbandonedOutput(conn)
                let suppressCancel = !cancelsOutput
                _ = finishPendingResults(conn, cancellingOutput: cancelsOutput)
                if let ended = sessionEndedBeforeSending(conn) {
                    continuation.finish(throwing: ended)
                    return
                }

                let sendOk = queryToRun.withCString { queryPtr in
                    PQsendQuery(conn, queryPtr)
                }

                if sendOk == 0 {
                    continuation.finish(throwing: lostConnection(getError(from: conn), on: conn, sent: false))
                    return
                }

                if PQsetSingleRowMode(conn) == 0 {
                    _ = cancelAndDrain(conn, suppressCancel: suppressCancel)
                    continuation.finish(throwing: LibPQPluginError(
                        message: "Failed to enter single-row mode", sqlState: nil, detail: nil))
                    return
                }

                var headerSent = false
                var columnOids: [UInt32] = []
                var lastCommandTag: String?
                let batchSize = 5_000
                var batch: [PluginRow] = []
                batch.reserveCapacity(batchSize)

                while let result = PQgetResult(conn) {
                    let status = PQresultStatus(result)

                    if status == PGRES_SINGLE_TUPLE {
                        if !headerSent {
                            let numFields = Int(PQnfields(result))
                            var columns: [String] = []
                            var columnTypeNames: [String] = []
                            columns.reserveCapacity(numFields)
                            columnOids.reserveCapacity(numFields)
                            columnTypeNames.reserveCapacity(numFields)

                            for i in 0..<numFields {
                                if let namePtr = PQfname(result, Int32(i)) {
                                    columns.append(String(cString: namePtr))
                                } else {
                                    columns.append("column_\(i)")
                                }
                                let oid = UInt32(PQftype(result, Int32(i)))
                                columnOids.append(oid)
                                columnTypeNames.append(typeNames.name(for: oid))
                            }

                            continuation.yield(.header(PluginStreamHeader(
                                columns: columns,
                                columnTypeNames: columnTypeNames,
                                estimatedRowCount: nil
                            )))
                            headerSent = true
                        }

                        let numFields = Int(PQnfields(result))
                        var row: [PluginCellValue] = []
                        row.reserveCapacity(numFields)

                        for colIndex in 0..<numFields {
                            row.append(Self.decodeCell(
                                from: result,
                                row: 0,
                                column: Int32(colIndex),
                                oid: columnOids[colIndex]
                            ))
                        }

                        PQclear(result)
                        batch.append(row)
                        if batch.count >= batchSize {
                            continuation.yield(.rows(batch))
                            batch.removeAll(keepingCapacity: true)
                        }

                        if abort.isAborted || cancellationGate.isCancelled(generation) {
                            if !batch.isEmpty {
                                continuation.yield(.rows(batch))
                            }
                            _ = cancelAndDrain(conn, suppressCancel: suppressCancel)
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                    } else if status == PGRES_TUPLES_OK {
                        PQclear(result)
                        break
                    } else if status == PGRES_COMMAND_OK {
                        lastCommandTag = getCommandTag(from: result)
                        PQclear(result)
                        break
                    } else if let copy = LibPQCopyState.copy(of: result) {
                        PQclear(result)
                        continuation.finish(throwing: abandonedCopyError(
                            copy, conn: conn, cancellingOutput: cancelsOutput, generation: generation))
                        return
                    } else {
                        let error = getResultError(from: result)
                        PQclear(result)
                        _ = finishPendingResults(conn, cancellingOutput: cancelsOutput)
                        recordTransactionState(of: conn)
                        if cancellationGate.isCancelled(generation) {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        continuation.finish(throwing: lostConnection(error, on: conn, sent: true))
                        return
                    }
                }

                if !batch.isEmpty {
                    continuation.yield(.rows(batch))
                }

                let outcome = finishPendingResults(conn, cancellingOutput: cancelsOutput)
                recordTransactionState(of: conn)
                /// The header went out with the first row, so this stream keeps what it said;
                /// the lookup is for the results that follow.
                let missing = typeNames.unresolvedOids(in: columnOids)
                if !missing.isEmpty {
                    learnTypeNames(for: missing, conn: conn)
                }
                noteCommandTag(lastCommandTag, conn: conn)
                if let abandoned = abandonedCopyError(outcome, generation: generation) {
                    continuation.finish(throwing: abandoned)
                    return
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Private Helpers

    var hasLostConnection: Bool {
        stateLock.withLock { _hasLostConnection }
    }

    private var lastTransactionState: LibPQTransactionState {
        stateLock.withLock { _lastTransactionState }
    }

    private var sessionEndingMessage: LibPQPluginError? {
        stateLock.withLock { serverMessages }?.takeUnretainedValue().sessionEndingMessage
    }

    private func recordTransactionState(of conn: OpaquePointer) {
        guard PQstatus(conn) == CONNECTION_OK else { return }
        let state = Self.transactionState(PQtransactionStatus(conn))
        stateLock.withLock { _lastTransactionState = state }
    }

    private func sessionEndedBeforeSending(_ conn: OpaquePointer) -> LibPQConnectionLostError? {
        recordTransactionState(of: conn)
        /// All three calls earn their place, measured against a terminated backend on 9.1.24 and
        /// 17.11. One `PQconsumeInput` leaves the status `CONNECTION_OK`, so a single read never
        /// sees the loss; the second one turns it `CONNECTION_BAD`. `PQisBusy` never moves the
        /// status, but it is what parses the buffered message: without it every closed-session
        /// case loses the server's FATAL and its SQLSTATE and reports libpq's own "server closed
        /// the connection unexpectedly" instead.
        if PQstatus(conn) == CONNECTION_OK {
            _ = PQconsumeInput(conn)
            _ = PQisBusy(conn)
            _ = PQconsumeInput(conn)
        }
        guard PQstatus(conn) == CONNECTION_BAD else {
            stateLock.withLock { serverMessages }?.takeUnretainedValue().clearIfHealthy()
            return nil
        }
        let serverMessage = sessionEndingMessage
        let loss = LibPQConnectionLoss(sent: false, recordedState: lastTransactionState)
        stateLock.withLock { _hasLostConnection = true }
        Self.logger.info("Server closed the session before a statement was sent")
        return LibPQConnectionLostError(loss: loss, underlying: serverMessage ?? getError(from: conn))
    }

    private func lostConnection(_ error: LibPQPluginError, on conn: OpaquePointer, sent: Bool) -> Error {
        guard PQstatus(conn) == CONNECTION_BAD else { return error }
        let loss = LibPQConnectionLoss(sent: sent, recordedState: lastTransactionState)
        stateLock.withLock {
            if sent { _lastTransactionState = .unknown }
            _hasLostConnection = true
        }
        let phase = sent ? "while a statement was running" : "while sending a statement"
        Self.logger.warning("Connection lost \(phase, privacy: .public)")
        return LibPQConnectionLostError(loss: loss, underlying: sessionEndingMessage ?? error)
    }

    private static func transactionState(_ status: PGTransactionStatusType) -> LibPQTransactionState {
        switch status {
        case PQTRANS_IDLE: return .idle
        case PQTRANS_ACTIVE: return .active
        case PQTRANS_INTRANS: return .inTransaction
        case PQTRANS_INERROR: return .inError
        default: return .unknown
        }
    }

    private func getError(from conn: OpaquePointer) -> LibPQPluginError {
        var message = "Unknown error"
        if let msgPtr = PQerrorMessage(conn) {
            message = String(cString: msgPtr).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return LibPQPluginError(message: message, sqlState: nil, detail: nil)
    }
}
