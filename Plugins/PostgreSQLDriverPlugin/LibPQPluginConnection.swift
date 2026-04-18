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

// MARK: - SSL Configuration

struct PQSSLConfig {
    var mode: String = "Disabled"
    var caCertificatePath: String = ""
    var clientCertificatePath: String = ""
    var clientKeyPath: String = ""

    init() {}

    init(additionalFields: [String: String]) {
        self.mode = additionalFields["sslMode"] ?? "Disabled"
        self.caCertificatePath = additionalFields["sslCaCertPath"] ?? ""
        self.clientCertificatePath = additionalFields["sslClientCertPath"] ?? ""
        self.clientKeyPath = additionalFields["sslClientKeyPath"] ?? ""
    }

    var libpqSslMode: String {
        switch mode {
        case "Disabled": return "disable"
        case "Preferred": return "prefer"
        case "Required": return "require"
        case "Verify CA": return "verify-ca"
        case "Verify Identity": return "verify-full"
        default: return "disable"
        }
    }

    var verifiesCertificate: Bool {
        mode == "Verify CA" || mode == "Verify Identity"
    }
}

// MARK: - Error Types

struct LibPQPluginError: Error {
    let message: String
    let sqlState: String?
    let detail: String?

    static let notConnected = LibPQPluginError(
        message: String(localized: "Not connected to database"), sqlState: nil, detail: nil)
    static let connectionFailed = LibPQPluginError(
        message: String(localized: "Failed to establish connection"), sqlState: nil, detail: nil)
}

// MARK: - Query Result

struct LibPQPluginQueryResult {
    let columns: [String]
    let columnOids: [UInt32]
    let columnTypeNames: [String]
    let rows: [[String?]]
    let affectedRows: Int
    let commandTag: String?
    let isTruncated: Bool
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
    private var conn: OpaquePointer?
    private let queue = DispatchQueue(label: "com.TablePro.libpq.plugin", qos: .userInitiated)

    private let host: String
    private let port: Int
    private let user: String
    private let password: String?
    private let database: String
    private let sslConfig: PQSSLConfig

    private let stateLock = NSLock()
    private var _isConnected: Bool = false
    private var _isShuttingDown: Bool = false
    private var _cachedServerVersion: String?
    private var _isCancelled: Bool = false

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
        sslConfig: PQSSLConfig = PQSSLConfig()
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.sslConfig = sslConfig
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

    func connect() async throws {
        try await pluginDispatchAsync(on: queue) { [self] in
            func escapeConnParam(_ value: String) -> String {
                value.replacingOccurrences(of: "\\", with: "\\\\")
                     .replacingOccurrences(of: "'", with: "\\'")
            }

            var connStr = "host='\(escapeConnParam(host))' port='\(port)' dbname='\(escapeConnParam(database))' connect_timeout='10'"

            if !user.isEmpty {
                connStr += " user='\(escapeConnParam(user))'"
            }

            if let password = password, !password.isEmpty {
                connStr += " password='\(escapeConnParam(password))'"
            }

            connStr += " sslmode='\(sslConfig.libpqSslMode)'"

            if sslConfig.verifiesCertificate, !sslConfig.caCertificatePath.isEmpty {
                connStr += " sslrootcert='\(escapeConnParam(sslConfig.caCertificatePath))'"
            }
            if !sslConfig.clientCertificatePath.isEmpty {
                connStr += " sslcert='\(escapeConnParam(sslConfig.clientCertificatePath))'"
            }
            if !sslConfig.clientKeyPath.isEmpty {
                connStr += " sslkey='\(escapeConnParam(sslConfig.clientKeyPath))'"
            }

            let connection = connStr.withCString { cStr in
                PQconnectdb(cStr)
            }

            guard let connection = connection else {
                throw LibPQPluginError.connectionFailed
            }

            if PQstatus(connection) != CONNECTION_OK {
                let error = self.getError(from: connection)
                PQfinish(connection)
                throw error
            }

            "SET client_encoding TO 'UTF8'".withCString { cStr in
                let result = PQexec(connection, cStr)
                PQclear(result)
            }

            let version = PQserverVersion(connection)
            if version > 0 {
                let major = version / 10_000
                if major >= 10 {
                    let minor = version % 10_000
                    self._cachedServerVersion = "\(major).\(minor)"
                } else {
                    let minor = (version / 100) % 100
                    let revision = version % 100
                    self._cachedServerVersion = "\(major).\(minor).\(revision)"
                }
            }

            self.stateLock.lock()
            self.conn = connection
            self._isConnected = true
            self.stateLock.unlock()
        }
    }

    func disconnect() {
        isShuttingDown = true

        stateLock.lock()
        _isConnected = false
        let handle = conn
        conn = nil
        stateLock.unlock()

        _cachedServerVersion = nil

        if let handle {
            queue.async {
                PQfinish(handle)
            }
        }
    }

    // MARK: - Query Cancellation

    func cancelCurrentQuery() {
        stateLock.lock()
        _isCancelled = true
        let currentConn = conn
        stateLock.unlock()

        guard let currentConn else { return }
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

    func executeParameterizedQuery(_ query: String, parameters: [String?]) async throws -> LibPQPluginQueryResult {
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
            let queryResult = try fetchResults(from: result)
            PQclear(result)
            return queryResult

        default:
            let error = getResultError(from: result)
            PQclear(result)
            throw error
        }
    }

    private func executeParameterizedQuerySync(_ query: String, parameters: [String?]) throws -> LibPQPluginQueryResult {
        stateLock.lock()
        let conn = self.conn
        stateLock.unlock()

        guard !isShuttingDown, let conn else {
            throw LibPQPluginError.notConnected
        }

        var paramValues: [UnsafePointer<CChar>?] = []

        defer {
            for ptr in paramValues {
                if let ptr = ptr {
                    free(UnsafeMutablePointer(mutating: ptr))
                }
            }
        }

        for param in parameters {
            if let param = param {
                let cStr = strdup(param)
                paramValues.append(UnsafePointer(cStr))
            } else {
                paramValues.append(nil)
            }
        }

        let localQuery = String(query)
        let result: OpaquePointer? = localQuery.withCString { queryPtr in
            PQexecParams(
                conn,
                queryPtr,
                Int32(parameters.count),
                nil,
                paramValues,
                nil,
                nil,
                0
            )
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
            let queryResult = try fetchResults(from: result)
            PQclear(result)
            return queryResult

        default:
            let error = getResultError(from: result)
            PQclear(result)
            throw error
        }
    }

    // MARK: - Streaming Query

    func streamQuery(_ query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let queryToRun = String(query)
        let queue = self.queue

        final class StreamState: @unchecked Sendable {
            var conn: OpaquePointer?
            var drained = false
            let lock = NSLock()
        }
        let streamState = StreamState()

        stateLock.lock()
        let connForStream = self.conn
        stateLock.unlock()

        streamState.lock.lock()
        streamState.conn = connForStream
        streamState.lock.unlock()

        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            continuation.onTermination = { @Sendable _ in
                queue.async {
                    streamState.lock.lock()
                    let conn = streamState.conn
                    let alreadyDrained = streamState.drained
                    streamState.drained = true
                    streamState.lock.unlock()
                    guard let conn, !alreadyDrained else { return }
                    let cancelObj = PQgetCancel(conn)
                    if let cancelObj {
                        var errbuf = [CChar](repeating: 0, count: 256)
                        PQcancel(cancelObj, &errbuf, Int32(errbuf.count))
                        PQfreeCancel(cancelObj)
                    }
                    while let res = PQgetResult(conn) { PQclear(res) }
                }
            }

            queue.async { [self] in
                guard !isShuttingDown, let conn = connForStream else {
                    continuation.finish(throwing: LibPQPluginError.notConnected)
                    return
                }

                let sendOk = queryToRun.withCString { queryPtr in
                    PQsendQuery(conn, queryPtr)
                }

                if sendOk == 0 {
                    streamState.lock.lock()
                    streamState.drained = true
                    streamState.lock.unlock()
                    continuation.finish(throwing: getError(from: conn))
                    return
                }

                if PQsetSingleRowMode(conn) == 0 {
                    while let res = PQgetResult(conn) { PQclear(res) }
                    streamState.lock.lock()
                    streamState.drained = true
                    streamState.lock.unlock()
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
                                columnTypeNames.append(pgOidToTypeName(oid))
                            }

                            continuation.yield(.header(PluginStreamHeader(
                                columns: columns,
                                columnTypeNames: columnTypeNames,
                                estimatedRowCount: nil
                            )))
                            headerSent = true
                        }

                        let numFields = Int(PQnfields(result))
                        var row: [String?] = []
                        row.reserveCapacity(numFields)

                        for colIndex in 0..<numFields {
                            if PQgetisnull(result, 0, Int32(colIndex)) == 1 {
                                row.append(nil)
                            } else if let valuePtr = PQgetvalue(result, 0, Int32(colIndex)) {
                                let length = Int(PQgetlength(result, 0, Int32(colIndex)))
                                let bufferPtr = UnsafeRawBufferPointer(start: valuePtr, count: length)

                                if let str = String(bytes: bufferPtr, encoding: .utf8) {
                                    if columnOids[colIndex] == 16 {
                                        row.append(str == "t" ? "true" : "false")
                                    } else {
                                        row.append(str)
                                    }
                                } else {
                                    row.append(String(bytes: bufferPtr, encoding: .isoLatin1) ?? "")
                                }
                            } else {
                                row.append(nil)
                            }
                        }

                        PQclear(result)
                        batch.append(row)
                        if batch.count >= batchSize {
                            continuation.yield(.rows(batch))
                            batch.removeAll(keepingCapacity: true)
                        }

                        if Task.isCancelled {
                            if !batch.isEmpty {
                                continuation.yield(.rows(batch))
                            }
                            let cancelObj = PQgetCancel(conn)
                            if let cancelObj {
                                var errbuf = [CChar](repeating: 0, count: 256)
                                PQcancel(cancelObj, &errbuf, Int32(errbuf.count))
                                PQfreeCancel(cancelObj)
                            }
                            while let res = PQgetResult(conn) { PQclear(res) }
                            streamState.lock.lock()
                            streamState.drained = true
                            streamState.lock.unlock()
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
                        streamState.lock.lock()
                        streamState.drained = true
                        streamState.lock.unlock()
                        continuation.finish(throwing: error)
                        return
                    }
                }

                if !batch.isEmpty {
                    continuation.yield(.rows(batch))
                }

                streamState.lock.lock()
                streamState.drained = true
                streamState.lock.unlock()
                continuation.finish()
            }
        }
    }

    // MARK: - Result Parsing

    private func fetchResults(from result: OpaquePointer) throws -> LibPQPluginQueryResult {
        let numFields = Int(PQnfields(result))
        let numRows = Int(PQntuples(result))

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

            let oid = PQftype(result, Int32(i))
            columnOids.append(UInt32(oid))
            columnTypeNames.append(pgOidToTypeName(UInt32(oid)))
        }

        let maxRows = PluginRowLimits.defaultMax
        let effectiveRowCount = min(numRows, maxRows)
        let truncated = numRows > maxRows

        var rows: [[String?]] = []
        rows.reserveCapacity(effectiveRowCount)

        for rowIndex in 0..<effectiveRowCount {
            stateLock.lock()
            let shouldCancel = _isCancelled
            if shouldCancel { _isCancelled = false }
            stateLock.unlock()
            if shouldCancel {
                PQclear(result)
                throw LibPQPluginError(message: "Query cancelled", sqlState: nil, detail: nil)
            }

            var row: [String?] = []
            row.reserveCapacity(numFields)

            for colIndex in 0..<numFields {
                if PQgetisnull(result, Int32(rowIndex), Int32(colIndex)) == 1 {
                    row.append(nil)
                } else if let valuePtr = PQgetvalue(result, Int32(rowIndex), Int32(colIndex)) {
                    let length = Int(PQgetlength(result, Int32(rowIndex), Int32(colIndex)))
                    let bufferPtr = UnsafeRawBufferPointer(start: valuePtr, count: length)

                    if let str = String(bytes: bufferPtr, encoding: .utf8) {
                        if columnOids[colIndex] == 16 {
                            row.append(str == "t" ? "true" : "false")
                        } else {
                            row.append(str)
                        }
                    } else {
                        row.append(String(bytes: bufferPtr, encoding: .isoLatin1) ?? "")
                    }
                } else {
                    row.append(nil)
                }
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
