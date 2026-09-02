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
import OSLog
import TableProPluginKit

private let logger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "LibPQPluginConnection")

// MARK: - Error Types

struct LibPQPluginError: Error {
    let message: String
    let sqlState: String?
    let detail: String?

    static let notConnected = LibPQPluginError(
        message: String(localized: "Not connected to database"), sqlState: nil, detail: nil)
    static let connectionFailed = LibPQPluginError(
        message: String(localized: "Failed to establish connection"), sqlState: nil, detail: nil)
    static let connectionTimedOut = LibPQPluginError(
        message: String(localized: "Timed out while connecting to the server"), sqlState: nil, detail: nil)
}

// MARK: - Query Result

struct LibPQPluginQueryResult {
    let columns: [String]
    let columnOids: [UInt32]
    let columnTypeNames: [String]
    let rows: [[PluginCellValue]]
    let affectedRows: Int
    let commandTag: String?
    let isTruncated: Bool

    /// Send to first row, when the read went through single-row mode and could see one. The
    /// buffered `PQexec` path has no such boundary and leaves it nil.
    var firstRowTime: TimeInterval?
}

// MARK: - Type Mapping

private func pgOidToTypeName(_ oid: UInt32) -> String {
    switch oid {
    case 16: return "boolean"
    case 17: return "bytea"
    case 18: return "char"
    case 19: return "name"
    case 20: return "bigint"
    case 21: return "smallint"
    case 23: return "integer"
    case 25: return "text"
    case 26: return "oid"
    case 114: return "json"
    case 142: return "xml"
    case 600: return "point"
    case 601: return "lseg"
    case 602: return "path"
    case 603: return "box"
    case 604: return "polygon"
    case 628: return "line"
    case 650: return "cidr"
    case 700: return "real"
    case 701: return "double precision"
    case 718: return "circle"
    case 829: return "macaddr"
    case 869: return "inet"
    case 1_009: return "text[]"
    case 1_000: return "boolean[]"
    case 1_001: return "bytea[]"
    case 1_005: return "smallint[]"
    case 1_007: return "integer[]"
    case 1_014: return "char[]"
    case 1_015: return "varchar[]"
    case 1_016: return "bigint[]"
    case 1_021: return "real[]"
    case 1_022: return "double precision[]"
    case 1_115: return "timestamp[]"
    case 1_182: return "date[]"
    case 1_183: return "time[]"
    case 1_185: return "timestamptz[]"
    case 1_187: return "interval[]"
    case 1_231: return "numeric[]"
    case 1_270: return "timetz[]"
    case 199: return "json[]"
    case 3_807: return "jsonb[]"
    case 2_951: return "uuid[]"
    case 1_041: return "inet[]"
    case 1_042: return "char"
    case 1_043: return "varchar"
    case 1_082: return "date"
    case 1_083: return "time"
    case 1_114: return "timestamp"
    case 1_184: return "timestamptz"
    case 1_266: return "timetz"
    case 1_700: return "numeric"
    case 2_950: return "uuid"
    case 3_802: return "jsonb"
    default: return "unknown"
    }
}

// MARK: - Connection Class

final class LibPQPluginConnection: @unchecked Sendable {
    private static let connectTimeoutMicroseconds: Int64 = 10_000_000
    private static let pollSliceMicroseconds: Int64 = 100_000

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
    private let cancellationGate = PluginQueryCancellationGate()
    private var _isConnected: Bool = false
    private var _isShuttingDown: Bool = false
    private var _cachedServerVersion: String?
    private var _cachedServerVersionNumber: Int32 = 0
    private var _isConnectCancelled: Bool = false
    private var _postgisOidMap: [UInt32: String] = [:]
    private var _enumOidMap: [UInt32: String] = [:]

    var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isConnected
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
        let cleanupQueue = queue
        conn = nil
        if let handle = handle {
            cleanupQueue.async {
                PQfinish(handle)
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
        guard let connection = buildConnectionString().withCString({ PQconnectStart($0) }) else {
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

        stateLock.lock()
        conn = connection
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
        "SET client_encoding TO 'UTF8'".withCString { cStr in
            let result = PQexec(connection, cStr)
            PQclear(result)
        }

        let version = PQserverVersion(connection)
        guard version > 0 else { return }

        _cachedServerVersionNumber = version
        let major = version / 10_000
        if major >= 10 {
            let minor = version % 10_000
            _cachedServerVersion = "\(major).\(minor)"
        } else {
            let minor = (version / 100) % 100
            let revision = version % 100
            _cachedServerVersion = "\(major).\(minor).\(revision)"
        }
    }

    private func buildConnectionString() -> String {
        func escapeConnParam(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "'", with: "\\'")
        }

        var connStr = "host='\(escapeConnParam(host))' port='\(port)' dbname='\(escapeConnParam(database))'"

        if !user.isEmpty {
            connStr += " user='\(escapeConnParam(user))'"
        }

        if let password, !password.isEmpty {
            connStr += " password='\(escapeConnParam(password))'"
        }

        connStr += " sslmode='\(LibPQSSLMapping.sslmode(for: sslConfig.mode))'"

        if sslConfig.verifiesCertificate, !sslConfig.caCertificatePath.isEmpty {
            connStr += " sslrootcert='\(escapeConnParam(sslConfig.caCertificatePath))'"
        }
        if !sslConfig.clientCertificatePath.isEmpty {
            connStr += " sslcert='\(escapeConnParam(sslConfig.clientCertificatePath))'"
        }
        if !sslConfig.clientKeyPath.isEmpty {
            connStr += " sslkey='\(escapeConnParam(sslConfig.clientKeyPath))'"
        }

        if let options, !options.isEmpty {
            connStr += " options='\(escapeConnParam(options))'"
        }

        return connStr
    }

    func disconnect() {
        isShuttingDown = true

        stateLock.lock()
        _isConnected = false
        _isConnectCancelled = true
        let handle = conn
        conn = nil
        stateLock.unlock()

        _cachedServerVersion = nil
        _cachedServerVersionNumber = 0

        if let handle {
            queue.async {
                PQfinish(handle)
            }
        }
    }

    // MARK: - PostGIS OID Map

    func setPostgisOidMap(_ map: [UInt32: String]) {
        stateLock.lock()
        _postgisOidMap = map
        stateLock.unlock()
    }

    private var postgisOidMap: [UInt32: String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _postgisOidMap
    }

    func setEnumOidMap(_ map: [UInt32: String]) {
        stateLock.lock()
        _enumOidMap = map
        stateLock.unlock()
    }

    private func resolveTypeName(_ oid: UInt32) -> String {
        stateLock.lock()
        let mapped = _enumOidMap[oid]
        stateLock.unlock()
        return mapped ?? pgOidToTypeName(oid)
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
        _cachedServerVersion
    }

    func serverVersionNumber() -> Int32 {
        _cachedServerVersionNumber
    }

    func currentDatabase() -> String {
        database
    }

    // MARK: - Synchronous Query Execution

    private func executeQuerySync(_ query: String) throws -> LibPQPluginQueryResult {
        stateLock.lock()
        let conn = self.conn
        stateLock.unlock()

        guard !isShuttingDown, let conn else {
            throw LibPQPluginError.notConnected
        }

        let generation = cancellationGate.beginQuery()
        defer { cancellationGate.endQuery(generation) }

        let localQuery = String(query)
        let result: OpaquePointer? = localQuery.withCString { queryPtr in
            PQexec(conn, queryPtr)
        }

        guard let result = result else {
            throw getError(from: conn)
        }

        let status = PQresultStatus(result)

        switch status {
        case PGRES_COMMAND_OK:
            let affected = getAffectedRows(from: result)
            let cmdTag = getCommandTag(from: result)
            PQclear(result)
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
            return try fetchResults(from: result, generation: generation)

        default:
            let error = getResultError(from: result)
            PQclear(result)
            if cancellationGate.isCancelled(generation) { throw CancellationError() }
            throw error
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
        stateLock.lock()
        let conn = self.conn
        stateLock.unlock()

        guard !isShuttingDown, let conn else {
            throw LibPQPluginError.notConnected
        }

        let generation = cancellationGate.beginQuery()
        defer { cancellationGate.endQuery(generation) }

        /// Started before the drain, so a result the previous statement abandoned is charged to the
        /// time before the first row rather than appearing as this query's row transfer.
        let sentAt = Date()
        while let stale = PQgetResult(conn) { PQclear(stale) }

        /// Cancelling a statement inside a transaction block puts the transaction into the aborted
        /// state, and every later command fails until ROLLBACK. Reading the tail of one result costs
        /// less than throwing away the transaction the user opened, so the cancel is withheld here
        /// and the connection is drained instead.
        let insideTransaction = PQtransactionStatus(conn) == PQTRANS_INTRANS
        let suppressCancel = suppressServerSideCancel || insideTransaction

        let localQuery = String(query)
        let sendOk = localQuery.withCString { queryPtr in
            PQsendQuery(conn, queryPtr)
        }
        guard sendOk != 0 else { throw getError(from: conn) }

        guard PQsetSingleRowMode(conn) != 0 else {
            Self.cancelAndDrain(conn, suppressCancel: suppressCancel)
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
                    Self.cancelAndDrain(conn, suppressCancel: suppressCancel)
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

            pendingError = getResultError(from: result)
            PQclear(result)
            break
        }

        if truncated {
            Self.cancelAndDrain(conn, suppressCancel: suppressCancel)
        } else {
            while let trailing = PQgetResult(conn) { PQclear(trailing) }
        }

        if let pendingError {
            if cancellationGate.isCancelled(generation) { throw CancellationError() }
            throw pendingError
        }
        if cancellationGate.isCancelled(generation) { throw CancellationError() }

        if truncated { rows.removeLast() }

        let bounded = LibPQPluginQueryResult(
            columns: metadata?.columns ?? [],
            columnOids: metadata?.columnOids ?? [],
            columnTypeNames: metadata?.columnTypeNames ?? [],
            rows: rows,
            affectedRows: affectedRows,
            commandTag: commandTag,
            isTruncated: truncated,
            firstRowTime: firstRowTime ?? Date().timeIntervalSince(sentAt)
        )
        return applySpatialRendering(to: bounded)
    }

    private func executeParameterizedQuerySync(_ query: String, parameters: [PluginCellValue]) throws -> LibPQPluginQueryResult {
        stateLock.lock()
        let conn = self.conn
        stateLock.unlock()

        guard !isShuttingDown, let conn else {
            throw LibPQPluginError.notConnected
        }

        let generation = cancellationGate.beginQuery()
        defer { cancellationGate.endQuery(generation) }

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
            throw getError(from: conn)
        }

        let status = PQresultStatus(result)

        switch status {
        case PGRES_COMMAND_OK:
            let affected = getAffectedRows(from: result)
            let cmdTag = getCommandTag(from: result)
            PQclear(result)
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
            return try fetchResults(from: result, generation: generation)

        default:
            let error = getResultError(from: result)
            PQclear(result)
            if cancellationGate.isCancelled(generation) { throw CancellationError() }
            throw error
        }
    }

    // MARK: - Streaming Query

    private static func cancelAndDrain(_ conn: OpaquePointer, suppressCancel: Bool) {
        if !suppressCancel {
            let cancelObj = PQgetCancel(conn)
            if let cancelObj {
                var errbuf = [CChar](repeating: 0, count: 256)
                PQcancel(cancelObj, &errbuf, Int32(errbuf.count))
                PQfreeCancel(cancelObj)
            }
        }
        while let res = PQgetResult(conn) { PQclear(res) }
    }

    /// The abort is polled by the producer rather than acted on from `onTermination`, because both
    /// run on one serial queue: a drain enqueued from the handler sits behind the producer and runs
    /// only once the whole result has been read, which is no abort at all.
    func streamQuery(_ query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let queryToRun = String(query)

        return PluginRowStream.make { continuation, abort in
            self.queue.async { [self] in
                stateLock.lock()
                let handle = self.conn
                stateLock.unlock()

                guard !isShuttingDown, let conn = handle else {
                    continuation.finish(throwing: LibPQPluginError.notConnected)
                    return
                }

                let generation = cancellationGate.beginQuery()
                defer { cancellationGate.endQuery(generation) }

                /// The consumer can go away before this block is scheduled, in which case the
                /// query is never sent at all.
                guard !abort.isAborted else {
                    continuation.finish()
                    return
                }

                while let res = PQgetResult(conn) { PQclear(res) }

                /// Read before the query goes out: once it is in flight the status is
                /// PQTRANS_ACTIVE, and the transaction this guard exists for is invisible.
                let suppressCancel = suppressServerSideCancel
                    || PQtransactionStatus(conn) == PQTRANS_INTRANS

                let sendOk = queryToRun.withCString { queryPtr in
                    PQsendQuery(conn, queryPtr)
                }

                if sendOk == 0 {
                    continuation.finish(throwing: getError(from: conn))
                    return
                }

                if PQsetSingleRowMode(conn) == 0 {
                    Self.cancelAndDrain(conn, suppressCancel: suppressCancel)
                    continuation.finish(throwing: LibPQPluginError(
                        message: "Failed to enter single-row mode", sqlState: nil, detail: nil))
                    return
                }

                var headerSent = false
                var columnOids: [UInt32] = []
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
                                columnTypeNames.append(resolveTypeName(oid))
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
                            Self.cancelAndDrain(conn, suppressCancel: suppressCancel)
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                    } else if status == PGRES_TUPLES_OK {
                        PQclear(result)
                        break
                    } else if status == PGRES_COMMAND_OK {
                        PQclear(result)
                        break
                    } else {
                        let error = getResultError(from: result)
                        PQclear(result)
                        while let res = PQgetResult(conn) { PQclear(res) }
                        if cancellationGate.isCancelled(generation) {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        continuation.finish(throwing: error)
                        return
                    }
                }

                if !batch.isEmpty {
                    continuation.yield(.rows(batch))
                }

                while let res = PQgetResult(conn) { PQclear(res) }
                continuation.finish()
            }
        }
    }

    // MARK: - Result Parsing

    private func fetchResults(from result: OpaquePointer, generation: Int) throws -> LibPQPluginQueryResult {
        let metadata = readColumnMetadata(from: result)
        let parsed = try parseRows(
            from: result,
            columns: metadata.columns,
            columnOids: metadata.columnOids,
            columnTypeNames: metadata.columnTypeNames,
            generation: generation
        )

        return applySpatialRendering(to: parsed)
    }

    private func applySpatialRendering(to result: LibPQPluginQueryResult) -> LibPQPluginQueryResult {
        let oidMap = postgisOidMap
        guard !oidMap.isEmpty else { return result }

        let spatialColumns = result.columnOids.enumerated().compactMap { index, oid -> (index: Int, typeName: String)? in
            guard let typeName = oidMap[oid] else { return nil }
            return (index, typeName)
        }
        guard !spatialColumns.isEmpty else { return result }

        return renderSpatialColumns(result, spatialColumns: spatialColumns)
    }

    private struct ColumnMetadata {
        let columns: [String]
        let columnOids: [UInt32]
        let columnTypeNames: [String]
    }

    private func readColumnMetadata(from result: OpaquePointer) -> ColumnMetadata {
        let numFields = Int(PQnfields(result))
        var columns: [String] = []
        var columnOids: [UInt32] = []
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
            columnTypeNames.append(resolveTypeName(oid))
        }
        return ColumnMetadata(columns: columns, columnOids: columnOids, columnTypeNames: columnTypeNames)
    }

    private func renderSpatialColumns(
        _ result: LibPQPluginQueryResult,
        spatialColumns: [(index: Int, typeName: String)]
    ) -> LibPQPluginQueryResult {
        var rows = result.rows
        var columnTypeNames = result.columnTypeNames

        for column in spatialColumns {
            if column.index < columnTypeNames.count {
                columnTypeNames[column.index] = column.typeName
            }

            guard let query = PostGISSpatialRewrite.conversionQuery(forTypeName: column.typeName) else { continue }

            let hexValues: [String?] = rows.map { row in
                guard column.index < row.count, case let .text(hex) = row[column.index] else { return nil }
                return hex
            }
            guard hexValues.contains(where: { $0 != nil }) else { continue }

            guard let converted = convertSpatialValues(hexValues, query: query),
                  converted.count == hexValues.count else {
                logger.warning("PostGIS value conversion failed for column \(column.index); keeping raw hex")
                continue
            }

            for (rowIndex, value) in converted.enumerated()
                where hexValues[rowIndex] != nil && column.index < rows[rowIndex].count {
                rows[rowIndex][column.index] = value
            }
        }

        return LibPQPluginQueryResult(
            columns: result.columns,
            columnOids: result.columnOids,
            columnTypeNames: columnTypeNames,
            rows: rows,
            affectedRows: result.affectedRows,
            commandTag: result.commandTag,
            isTruncated: result.isTruncated,
            firstRowTime: result.firstRowTime
        )
    }

    private func convertSpatialValues(_ hexValues: [String?], query: String) -> [PluginCellValue]? {
        stateLock.lock()
        let conn = self.conn
        stateLock.unlock()
        guard let conn else { return nil }

        let arrayLiteral = PostGISSpatialRewrite.arrayLiteral(from: hexValues)
        guard let paramCStr = strdup(arrayLiteral) else { return nil }
        defer { free(paramCStr) }

        let paramValues: [UnsafePointer<CChar>?] = [UnsafePointer(paramCStr)]
        let result: OpaquePointer? = query.withCString { queryPtr in
            PQexecParams(conn, queryPtr, 1, nil, paramValues, nil, nil, 0)
        }

        guard let result, PQresultStatus(result) == PGRES_TUPLES_OK else {
            if let result { PQclear(result) }
            return nil
        }
        defer { PQclear(result) }

        let rowCount = Int(PQntuples(result))
        var converted: [PluginCellValue] = []
        converted.reserveCapacity(rowCount)
        for rowIndex in 0..<rowCount {
            if PQgetisnull(result, Int32(rowIndex), 0) == 1 {
                converted.append(.null)
            } else if let valuePtr = PQgetvalue(result, Int32(rowIndex), 0) {
                let length = Int(PQgetlength(result, Int32(rowIndex), 0))
                let bufferPtr = UnsafeRawBufferPointer(start: valuePtr, count: length)
                converted.append(.text(String(bytes: bufferPtr, encoding: .utf8) ?? ""))
            } else {
                converted.append(.null)
            }
        }
        return converted
    }

    private static func decodeCell(
        from result: OpaquePointer,
        row: Int32,
        column: Int32,
        oid: UInt32
    ) -> PluginCellValue {
        guard PQgetisnull(result, row, column) != 1,
              let valuePtr = PQgetvalue(result, row, column) else {
            return .null
        }

        let length = Int(PQgetlength(result, row, column))
        let bufferPtr = UnsafeRawBufferPointer(start: valuePtr, count: length)

        if oid == 17 {
            let text = String(bytes: bufferPtr, encoding: .utf8) ?? ""
            guard let data = LibPQByteaDecoder.decode(text) else { return .text(text) }
            return .bytes(data)
        }

        if oid == 16 {
            let str = String(bytes: bufferPtr, encoding: .utf8) ?? ""
            return .text(str == "t" ? "true" : "false")
        }

        if let str = String(bytes: bufferPtr, encoding: .utf8) { return .text(str) }
        return .text(String(bytes: bufferPtr, encoding: .isoLatin1) ?? "")
    }

    private func parseRows(
        from result: OpaquePointer,
        columns: [String],
        columnOids: [UInt32],
        columnTypeNames: [String],
        generation: Int
    ) throws -> LibPQPluginQueryResult {
        let numFields = columns.count
        let numRows = Int(PQntuples(result))

        let maxRows = PluginRowLimits.emergencyMax
        let effectiveRowCount = min(numRows, maxRows)
        let truncated = numRows > maxRows

        var rows: [[PluginCellValue]] = []
        rows.reserveCapacity(effectiveRowCount)

        for rowIndex in 0..<effectiveRowCount {
            if cancellationGate.isCancelled(generation) {
                throw CancellationError()
            }

            var row: [PluginCellValue] = []
            row.reserveCapacity(numFields)

            for colIndex in 0..<numFields {
                row.append(Self.decodeCell(
                    from: result,
                    row: Int32(rowIndex),
                    column: Int32(colIndex),
                    oid: columnOids[colIndex]
                ))
            }
            rows.append(row)
        }

        if truncated {
            logger.warning("Result set truncated at \(maxRows) rows")
        }

        return LibPQPluginQueryResult(
            columns: columns,
            columnOids: columnOids,
            columnTypeNames: columnTypeNames,
            rows: rows,
            affectedRows: numRows,
            commandTag: getCommandTag(from: result),
            isTruncated: truncated
        )
    }

    // MARK: - Private Helpers

    private func getError(from conn: OpaquePointer) -> LibPQPluginError {
        var message = "Unknown error"
        if let msgPtr = PQerrorMessage(conn) {
            message = String(cString: msgPtr).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return LibPQPluginError(message: message, sqlState: nil, detail: nil)
    }

    private func getResultError(from result: OpaquePointer) -> LibPQPluginError {
        var message = "Unknown error"
        var sqlState: String?
        var detail: String?

        if let msgPtr = PQresultErrorMessage(result) {
            message = String(cString: msgPtr).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let statePtr = PQresultErrorField(result, Int32(80)) {
            sqlState = String(cString: statePtr)
        }

        if let detailPtr = PQresultErrorField(result, Int32(68)) {
            detail = String(cString: detailPtr)
        }

        return LibPQPluginError(message: message, sqlState: sqlState, detail: detail)
    }

    private func getAffectedRows(from result: OpaquePointer) -> Int {
        if let affectedPtr = PQcmdTuples(result), affectedPtr.pointee != 0 {
            return Int(String(cString: affectedPtr)) ?? 0
        }
        return 0
    }

    private func getCommandTag(from result: OpaquePointer) -> String? {
        if let tagPtr = PQcmdStatus(result), tagPtr.pointee != 0 {
            return String(cString: tagPtr)
        }
        return nil
    }
}

// MARK: - PluginDriverError Conformance

extension LibPQPluginError: PluginDriverError {
    var pluginErrorMessage: String { message }
    var pluginSqlState: String? { sqlState }
    var pluginErrorDetail: String? { detail }
}
