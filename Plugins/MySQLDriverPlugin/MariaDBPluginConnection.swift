//
//  MariaDBPluginConnection.swift
//  MySQLDriverPlugin
//
//  Swift wrapper around libmariadb (MariaDB Connector/C)
//  Provides thread-safe, async-friendly MySQL/MariaDB connections
//

import CMariaDB
import Foundation
import OSLog
import TableProPluginKit

// MySQL/MariaDB field flag and charset constants
private let mysqlBinaryFlag: UInt = 0x0080
private let mysqlEnumFlag: UInt = 0x0100
private let mysqlSetFlag: UInt = 0x0800
private let mysqlBinaryCharset: UInt32 = 63

private let logger = Logger(subsystem: "com.TablePro", category: "MariaDBPluginConnection")

// MARK: - Error Types

struct MariaDBPluginError: Error {
    let code: UInt32
    let message: String
    let sqlState: String?

    static let notConnected = MariaDBPluginError(
        code: 0, message: String(localized: "Not connected to database"), sqlState: nil)
    static let connectionFailed = MariaDBPluginError(
        code: 0, message: String(localized: "Failed to establish connection"), sqlState: nil)
    static let initFailed = MariaDBPluginError(
        code: 0, message: String(localized: "Failed to initialize MySQL client"), sqlState: nil)
}

// MARK: - Query Result

struct MariaDBPluginQueryResult {
    let columns: [String]
    let columnTypes: [UInt32]
    let columnTypeNames: [String]
    let rows: [[String?]]
    let affectedRows: UInt64
    let insertId: UInt64
    let isTruncated: Bool
}

// MARK: - SSL Configuration

struct MySQLSSLConfig {
    enum Mode: String {
        case disabled = "Disabled"
        case preferred = "Preferred"
        case required = "Required"
        case verifyCa = "Verify CA"
        case verifyIdentity = "Verify Identity"
    }

    let mode: Mode
    let caCertificatePath: String
    let clientCertificatePath: String
    let clientKeyPath: String

    init(from fields: [String: String]) {
        self.mode = Mode(rawValue: fields["sslMode"] ?? "Disabled") ?? .disabled
        self.caCertificatePath = fields["sslCaCertPath"] ?? ""
        self.clientCertificatePath = fields["sslClientCertPath"] ?? ""
        self.clientKeyPath = fields["sslClientKeyPath"] ?? ""
    }
}


// MARK: - Type Mapping

func mysqlTypeToString(_ fieldPtr: UnsafePointer<MYSQL_FIELD>) -> String {
    let field = fieldPtr.pointee
    let flags = UInt(field.flags)
    let length = field.length

    // MariaDB extended metadata: detect JSON stored as LONGTEXT (best-effort)
    var attr = MARIADB_CONST_STRING()
    if mariadb_field_attr(&attr, fieldPtr, MARIADB_FIELD_ATTR_FORMAT_NAME) == 0,
       let str = attr.str, attr.length > 0,
       String(cString: str) == "json" {
        return "JSON"
    }

    if (flags & mysqlEnumFlag) != 0 { return "ENUM" }
    if (flags & mysqlSetFlag) != 0 { return "SET" }

    // Binary flag alone is insufficient — MariaDB sets it on text columns with
    // binary collation (e.g. utf8mb4_bin for JSON). Only charset 63 is truly binary.
    let isBinary = (flags & mysqlBinaryFlag) != 0 && field.charsetnr == mysqlBinaryCharset

    switch field.type.rawValue {
    case 0: return "DECIMAL"
    case 1: return "TINYINT"
    case 2: return "SMALLINT"
    case 3: return "INT"
    case 4: return "FLOAT"
    case 5: return "DOUBLE"
    case 6: return "NULL"
    case 7: return "TIMESTAMP"
    case 8: return "BIGINT"
    case 9: return "MEDIUMINT"
    case 10: return "DATE"
    case 11: return "TIME"
    case 12: return "DATETIME"
    case 13: return "YEAR"
    case 14: return "NEWDATE"
    case 15: return "VARCHAR"
    case 16: return "BIT"
    case 245: return "JSON"
    case 246: return "NEWDECIMAL"
    case 247: return "ENUM"
    case 248: return "SET"
    case 249:
        return isBinary ? "TINYBLOB" : "TINYTEXT"
    case 250:
        return isBinary ? "MEDIUMBLOB" : "MEDIUMTEXT"
    case 251:
        return isBinary ? "LONGBLOB" : "LONGTEXT"
    case 252:
        if isBinary {
            return length > 65_535 ? "LONGBLOB" : "BLOB"
        } else {
            return length > 65_535 ? "LONGTEXT" : "TEXT"
        }
    case 253: return "VARCHAR"
    case 254: return "CHAR"
    case 255: return "GEOMETRY"
    default: return "UNKNOWN"
    }
}

// MARK: - Connection Class

final class MariaDBPluginConnection: @unchecked Sendable {
    private var mysql: UnsafeMutablePointer<MYSQL>?
    private let queue = DispatchQueue(label: "com.TablePro.mariadb.plugin", qos: .userInitiated)

    private let host: String
    private let port: UInt32
    private let user: String
    private let password: String?
    private let database: String
    private let sslConfig: MySQLSSLConfig

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
        sslConfig: MySQLSSLConfig
    ) {
        self.host = host
        self.port = UInt32(port)
        self.user = user
        self.password = password
        self.database = database
        self.sslConfig = sslConfig
    }

    deinit {
        let handle = mysql
        let cleanupQueue = queue
        mysql = nil
        if let handle = handle {
            cleanupQueue.async {
                mysql_close(handle)
            }
        }
    }

    // MARK: - Connection Management

    func connect() async throws {
        try await pluginDispatchAsync(on: queue) { [self] in
            guard let mysql = mysql_init(nil) else {
                throw MariaDBPluginError.initFailed
            }

            self.mysql = mysql

            var reconnect: my_bool = 0
            mysql_options(mysql, MYSQL_OPT_RECONNECT, &reconnect)

            var timeout: UInt32 = 10
            mysql_options(mysql, MYSQL_OPT_CONNECT_TIMEOUT, &timeout)

            var readTimeout: UInt32 = 30
            mysql_options(mysql, MYSQL_OPT_READ_TIMEOUT, &readTimeout)

            var writeTimeout: UInt32 = 30
            mysql_options(mysql, MYSQL_OPT_WRITE_TIMEOUT, &writeTimeout)

            var protocol_tcp = UInt32(MYSQL_PROTOCOL_TCP.rawValue)
            mysql_options(mysql, MYSQL_OPT_PROTOCOL, &protocol_tcp)

            switch self.sslConfig.mode {
            case .disabled, .preferred:
                var sslEnforce: my_bool = 0
                mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &sslEnforce)
                var sslVerify: my_bool = 0
                mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &sslVerify)

            case .required:
                var sslEnforce: my_bool = 1
                mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &sslEnforce)
                var sslVerify: my_bool = 0
                mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &sslVerify)

            case .verifyCa, .verifyIdentity:
                var sslEnforce: my_bool = 1
                mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &sslEnforce)
                var sslVerify: my_bool = 1
                mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &sslVerify)
            }

            if !self.sslConfig.caCertificatePath.isEmpty {
                _ = self.sslConfig.caCertificatePath.withCString { path in
                    mysql_options(mysql, MYSQL_OPT_SSL_CA, path)
                }
            }
            if !self.sslConfig.clientCertificatePath.isEmpty {
                _ = self.sslConfig.clientCertificatePath.withCString { path in
                    mysql_options(mysql, MYSQL_OPT_SSL_CERT, path)
                }
            }
            if !self.sslConfig.clientKeyPath.isEmpty {
                _ = self.sslConfig.clientKeyPath.withCString { path in
                    mysql_options(mysql, MYSQL_OPT_SSL_KEY, path)
                }
            }

            mysql_options(mysql, MYSQL_SET_CHARSET_NAME, "utf8mb4")

            let dbToUse = self.database.isEmpty ? nil : self.database
            let passToUse = self.password

            let result: UnsafeMutablePointer<MYSQL>?

            if let db = dbToUse, let pass = passToUse {
                result = self.host.withCString { hostPtr in
                    self.user.withCString { userPtr in
                        pass.withCString { passPtr in
                            db.withCString { dbPtr in
                                mysql_real_connect(
                                    mysql, hostPtr, userPtr, passPtr, dbPtr,
                                    self.port, nil, 0
                                )
                            }
                        }
                    }
                }
            } else if let db = dbToUse {
                result = self.host.withCString { hostPtr in
                    self.user.withCString { userPtr in
                        db.withCString { dbPtr in
                            mysql_real_connect(
                                mysql, hostPtr, userPtr, nil, dbPtr,
                                self.port, nil, 0
                            )
                        }
                    }
                }
            } else if let pass = passToUse {
                result = self.host.withCString { hostPtr in
                    self.user.withCString { userPtr in
                        pass.withCString { passPtr in
                            mysql_real_connect(
                                mysql, hostPtr, userPtr, passPtr, nil,
                                self.port, nil, 0
                            )
                        }
                    }
                }
            } else {
                result = self.host.withCString { hostPtr in
                    self.user.withCString { userPtr in
                        mysql_real_connect(
                            mysql, hostPtr, userPtr, nil, nil,
                            self.port, nil, 0
                        )
                    }
                }
            }

            if result == nil {
                let error = self.getError()
                mysql_close(mysql)
                self.mysql = nil
                throw error
            }

            if let versionPtr = mysql_get_server_info(mysql) {
                self._cachedServerVersion = String(cString: versionPtr)
            }

            self.stateLock.lock()
            self._isConnected = true
            self.stateLock.unlock()
        }
    }

    func disconnect() {
        isShuttingDown = true

        let handle = mysql
        mysql = nil

        stateLock.lock()
        _isConnected = false
        stateLock.unlock()

        _cachedServerVersion = nil

        if let handle = handle {
            queue.async {
                mysql_close(handle)
            }
        }
    }

    // MARK: - Query Cancellation

    func cancelCurrentQuery() {
        stateLock.lock()
        _isCancelled = true
        stateLock.unlock()

        guard let mysql = mysql else { return }
        let threadId = mysql_thread_id(mysql)
        guard threadId > 0 else { return }

        let killConn = mysql_init(nil)
        guard let killConn = killConn else { return }

        var killTimeout: UInt32 = 5
        mysql_options(killConn, MYSQL_OPT_CONNECT_TIMEOUT, &killTimeout)

        let killResult = host.withCString { hostPtr in
            user.withCString { userPtr in
                if let pass = password {
                    return pass.withCString { passPtr in
                        mysql_real_connect(killConn, hostPtr, userPtr, passPtr, nil, port, nil, 0)
                    }
                } else {
                    return mysql_real_connect(killConn, hostPtr, userPtr, nil, nil, port, nil, 0)
                }
            }
        }

        if killResult != nil {
            let killQuery = "KILL QUERY \(threadId)"
            _ = killQuery.withCString { queryPtr in
                mysql_real_query(killConn, queryPtr, UInt(killQuery.utf8.count))
            }
        }

        mysql_close(killConn)
    }

    // MARK: - Query Execution

    func executeQuery(_ query: String) async throws -> MariaDBPluginQueryResult {
        let queryToRun = String(query)

        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown else { throw MariaDBPluginError.notConnected }
            return try executeQuerySync(queryToRun)
        }
    }

    func executeParameterizedQuery(_ query: String, parameters: [Any?]) async throws -> MariaDBPluginQueryResult {
        let queryToRun = String(query)
        let params = parameters

        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown else { throw MariaDBPluginError.notConnected }
            return try executeParameterizedQuerySync(queryToRun, parameters: params)
        }
    }

    private func executeQuerySync(_ query: String) throws -> MariaDBPluginQueryResult {
        guard !isShuttingDown, let mysql = self.mysql else {
            throw MariaDBPluginError.notConnected
        }

        let queryStatus = query.withCString { queryPtr in
            mysql_real_query(mysql, queryPtr, UInt(query.utf8.count))
        }

        if queryStatus != 0 {
            throw self.getError()
        }

        let resultPtr = mysql_use_result(mysql)

        if resultPtr == nil {
            let fieldCount = mysql_field_count(mysql)
            if fieldCount == 0 {
                let affected = mysql_affected_rows(mysql)
                let insertId = mysql_insert_id(mysql)
                return MariaDBPluginQueryResult(
                    columns: [], columnTypes: [], columnTypeNames: [],
                    rows: [], affectedRows: affected, insertId: insertId, isTruncated: false
                )
            } else {
                throw self.getError()
            }
        }

        let numFields = Int(mysql_num_fields(resultPtr))
        var columns: [String] = []
        var columnTypes: [UInt32] = []
        var columnTypeNames: [String] = []
        columns.reserveCapacity(numFields)
        columnTypes.reserveCapacity(numFields)
        columnTypeNames.reserveCapacity(numFields)

        if let fields = mysql_fetch_fields(resultPtr) {
            for i in 0..<numFields {
                let field = fields[i]
                if let namePtr = field.name {
                    columns.append(String(cString: namePtr))
                } else {
                    columns.append("column_\(i)")
                }
                let fieldFlags = UInt(field.flags)
                var fieldType = field.type.rawValue
                if (fieldFlags & mysqlEnumFlag) != 0 { fieldType = 247 }
                if (fieldFlags & mysqlSetFlag) != 0 { fieldType = 248 }
                columnTypes.append(fieldType)
                columnTypeNames.append(mysqlTypeToString(fields + i))
            }
        }

        var rows: [[String?]] = []
        rows.reserveCapacity(min(1_000, PluginRowLimits.defaultMax))

        let maxRows = PluginRowLimits.defaultMax
        var truncated = false

        while let rowPtr = mysql_fetch_row(resultPtr) {
            stateLock.lock()
            let shouldCancel = _isCancelled
            if shouldCancel { _isCancelled = false }
            stateLock.unlock()
            if shouldCancel {
                while mysql_fetch_row(resultPtr) != nil {}
                if mysql_errno(mysql) != 0 {
                    let errorMsg = String(cString: mysql_error(mysql))
                    mysql_free_result(resultPtr)
                    throw MariaDBPluginError(
                        code: mysql_errno(mysql),
                        message: "Error draining result set during cancellation: \(errorMsg)",
                        sqlState: nil)
                }
                mysql_free_result(resultPtr)
                throw MariaDBPluginError(code: 0, message: "Query cancelled", sqlState: nil)
            }

            if rows.count >= maxRows {
                truncated = true
                break
            }

            let lengths = mysql_fetch_lengths(resultPtr)

            var row: [String?] = []
            row.reserveCapacity(numFields)

            for i in 0..<numFields {
                if let fieldPtr = rowPtr[i] {
                    let lengthValue: UInt = lengths?[i] ?? 0
                    let length = Int(lengthValue)
                    let bufferPtr = UnsafeRawBufferPointer(start: fieldPtr, count: length)

                    if columnTypes[i] == 255 {
                        row.append(GeometryWKBParser.parse(bufferPtr))
                    } else if let str = String(bytes: bufferPtr, encoding: .utf8) {
                        row.append(str)
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
            while mysql_fetch_row(resultPtr) != nil {}
            if mysql_errno(mysql) != 0 {
                let errorMsg = String(cString: mysql_error(mysql))
                mysql_free_result(resultPtr)
                throw MariaDBPluginError(
                    code: mysql_errno(mysql),
                    message: "Error draining result set: \(errorMsg)",
                    sqlState: nil)
            }
        }

        mysql_free_result(resultPtr)

        return MariaDBPluginQueryResult(
            columns: columns, columnTypes: columnTypes, columnTypeNames: columnTypeNames,
            rows: rows, affectedRows: UInt64(rows.count), insertId: 0, isTruncated: truncated
        )
    }

    // MARK: - Prepared Statements

    private struct ParameterBindings {
        var binds: [MYSQL_BIND]
        var buffers: [UnsafeMutableRawPointer?]

        func cleanup() {
            for buffer in buffers where buffer != nil {
                buffer?.deallocate()
            }
            for bind in binds {
                bind.length?.deallocate()
                bind.is_null?.deallocate()
            }
        }
    }

    private func bindParameters(
        _ parameters: [Any?],
        toStatement stmt: UnsafeMutablePointer<MYSQL_STMT>
    ) throws -> ParameterBindings {
        let paramCount = parameters.count
        var binds: [MYSQL_BIND] = Array(repeating: MYSQL_BIND(), count: paramCount)
        var buffers: [UnsafeMutableRawPointer?] = []

        for (index, param) in parameters.enumerated() {
            if let param = param {
                let stringValue: String
                if let str = param as? String {
                    stringValue = str
                } else if let num = param as? any Numeric {
                    stringValue = "\(num)"
                } else {
                    stringValue = "\(param)"
                }

                let data = stringValue.data(using: .utf8) ?? Data()
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 1)
                data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)

                binds[index].buffer_type = MYSQL_TYPE_STRING
                binds[index].buffer = buffer
                binds[index].buffer_length = UInt(data.count)
                binds[index].length = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
                binds[index].length?.pointee = UInt(data.count)
                binds[index].is_null = UnsafeMutablePointer<my_bool>.allocate(capacity: 1)
                binds[index].is_null?.pointee = 0

                buffers.append(buffer)
            } else {
                binds[index].buffer_type = MYSQL_TYPE_NULL
                binds[index].is_null = UnsafeMutablePointer<my_bool>.allocate(capacity: 1)
                binds[index].is_null?.pointee = 1
            }
        }

        if mysql_stmt_bind_param(stmt, &binds) != 0 {
            let bindings = ParameterBindings(binds: binds, buffers: buffers)
            bindings.cleanup()
            throw getStmtError(stmt)
        }

        return ParameterBindings(binds: binds, buffers: buffers)
    }

    private func fetchResultSet(
        from stmt: UnsafeMutablePointer<MYSQL_STMT>,
        metadata: UnsafeMutablePointer<MYSQL_RES>,
        columns: [String],
        columnTypes: [UInt32],
        columnTypeNames: [String]
    ) throws -> (rows: [[String?]], isTruncated: Bool) {
        let numFields = columns.count
        var resultBinds: [MYSQL_BIND] = Array(repeating: MYSQL_BIND(), count: numFields)
        var resultBuffers: [UnsafeMutableRawPointer] = []

        defer {
            for buffer in resultBuffers {
                buffer.deallocate()
            }
            for bind in resultBinds {
                bind.length?.deallocate()
                bind.is_null?.deallocate()
                bind.error?.deallocate()
            }
        }

        for i in 0..<numFields {
            let bufferSize = 65_536
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
            resultBuffers.append(buffer)

            resultBinds[i].buffer_type = MYSQL_TYPE_STRING
            resultBinds[i].buffer = buffer
            resultBinds[i].buffer_length = UInt(bufferSize)
            resultBinds[i].length = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
            resultBinds[i].is_null = UnsafeMutablePointer<my_bool>.allocate(capacity: 1)
            resultBinds[i].error = UnsafeMutablePointer<my_bool>.allocate(capacity: 1)
        }

        if mysql_stmt_bind_result(stmt, &resultBinds) != 0 {
            throw getStmtError(stmt)
        }

        var rows: [[String?]] = []
        let maxRows = PluginRowLimits.defaultMax
        var truncated = false

        while true {
            let fetchStatus = mysql_stmt_fetch(stmt)
            if fetchStatus != 0 && fetchStatus != MYSQL_DATA_TRUNCATED { break }

            stateLock.lock()
            let shouldCancel = _isCancelled
            if shouldCancel { _isCancelled = false }
            stateLock.unlock()
            if shouldCancel {
                throw MariaDBPluginError(code: 0, message: "Query cancelled", sqlState: nil)
            }

            if rows.count >= maxRows {
                truncated = true
                break
            }

            // Re-fetch truncated columns with correctly sized buffers
            if fetchStatus == MYSQL_DATA_TRUNCATED {
                for i in 0..<numFields {
                    let actualLength = Int(resultBinds[i].length?.pointee ?? 0)
                    if actualLength > Int(resultBinds[i].buffer_length) {
                        let newBuffer = UnsafeMutableRawPointer.allocate(
                            byteCount: actualLength, alignment: 1
                        )
                        resultBuffers[i].deallocate()
                        resultBuffers[i] = newBuffer
                        resultBinds[i].buffer = newBuffer
                        resultBinds[i].buffer_length = UInt(actualLength)
                        if mysql_stmt_fetch_column(stmt, &resultBinds[i], UInt32(i), 0) != 0 {
                            logger.warning("mysql_stmt_fetch_column failed for column \(i)")
                        }
                    }
                }
            }

            var row: [String?] = []
            for i in 0..<numFields {
                if resultBinds[i].is_null?.pointee == 1 {
                    row.append(nil)
                } else {
                    let length = Int(resultBinds[i].length?.pointee ?? 0)
                    let buffer = resultBuffers[i].assumingMemoryBound(to: UInt8.self)
                    let data = Data(bytes: buffer, count: length)
                    if let str = String(data: data, encoding: .utf8) {
                        row.append(str)
                    } else {
                        row.append(nil)
                    }
                }
            }
            rows.append(row)
        }

        if truncated {
            logger.warning("Prepared statement result truncated at \(maxRows) rows")
        }

        return (rows: rows, isTruncated: truncated)
    }

    private func executeParameterizedQuerySync(_ query: String, parameters: [Any?]) throws -> MariaDBPluginQueryResult {
        guard !isShuttingDown, let mysql = self.mysql else {
            throw MariaDBPluginError.notConnected
        }

        guard let stmt = mysql_stmt_init(mysql) else {
            throw MariaDBPluginError(code: 0, message: "Failed to initialize prepared statement", sqlState: nil)
        }

        defer {
            mysql_stmt_close(stmt)
        }

        let prepareResult = query.withCString { queryPtr in
            mysql_stmt_prepare(stmt, queryPtr, UInt(query.utf8.count))
        }

        if prepareResult != 0 {
            throw getStmtError(stmt)
        }

        let paramCount = Int(mysql_stmt_param_count(stmt))
        guard paramCount == parameters.count else {
            throw MariaDBPluginError(
                code: 0,
                message: "Parameter count mismatch: expected \(paramCount), got \(parameters.count)",
                sqlState: nil
            )
        }

        if paramCount > 0 {
            let bindings = try bindParameters(parameters, toStatement: stmt)
            defer { bindings.cleanup() }

            if mysql_stmt_execute(stmt) != 0 {
                throw getStmtError(stmt)
            }
        } else {
            if mysql_stmt_execute(stmt) != 0 {
                throw getStmtError(stmt)
            }
        }

        let fieldCount = Int(mysql_stmt_field_count(stmt))

        if fieldCount == 0 {
            let affected = mysql_stmt_affected_rows(stmt)
            let insertId = mysql_stmt_insert_id(stmt)
            return MariaDBPluginQueryResult(
                columns: [], columnTypes: [], columnTypeNames: [],
                rows: [], affectedRows: UInt64(affected), insertId: UInt64(insertId), isTruncated: false
            )
        }

        guard let metadata = mysql_stmt_result_metadata(stmt) else {
            throw MariaDBPluginError(code: 0, message: "Failed to fetch result metadata", sqlState: nil)
        }

        defer {
            mysql_free_result(metadata)
        }

        var columns: [String] = []
        var columnTypes: [UInt32] = []
        var columnTypeNames: [String] = []
        let numFields = Int(mysql_num_fields(metadata))

        if let fields = mysql_fetch_fields(metadata) {
            for i in 0..<numFields {
                let field = fields[i]
                if let namePtr = field.name {
                    columns.append(String(cString: namePtr))
                } else {
                    columns.append("column_\(i)")
                }
                let fieldFlags = UInt(field.flags)
                var fieldType = field.type.rawValue
                if (fieldFlags & mysqlEnumFlag) != 0 { fieldType = 247 }
                if (fieldFlags & mysqlSetFlag) != 0 { fieldType = 248 }
                columnTypes.append(fieldType)
                columnTypeNames.append(mysqlTypeToString(fields + i))
            }
        }

        let fetchResult = try fetchResultSet(
            from: stmt, metadata: metadata,
            columns: columns, columnTypes: columnTypes, columnTypeNames: columnTypeNames
        )

        return MariaDBPluginQueryResult(
            columns: columns, columnTypes: columnTypes, columnTypeNames: columnTypeNames,
            rows: fetchResult.rows, affectedRows: UInt64(fetchResult.rows.count),
            insertId: 0, isTruncated: fetchResult.isTruncated
        )
    }

    // MARK: - Streaming Query

    func streamQuery(_ query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let queryToRun = String(query)
        let queue = self.queue

        final class StreamState: @unchecked Sendable {
            var resultPtr: UnsafeMutablePointer<MYSQL_RES>?
            var drained = false
            let lock = NSLock()
        }
        let streamState = StreamState()

        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            continuation.onTermination = { @Sendable _ in
                queue.async {
                    streamState.lock.lock()
                    let ptr = streamState.resultPtr
                    let alreadyDrained = streamState.drained
                    streamState.drained = true
                    streamState.lock.unlock()
                    guard let resultPtr = ptr, !alreadyDrained else { return }
                    while mysql_fetch_row(resultPtr) != nil {}
                    mysql_free_result(resultPtr)
                }
            }

            queue.async { [self] in
                guard !isShuttingDown, let mysql = self.mysql else {
                    continuation.finish(throwing: MariaDBPluginError.notConnected)
                    return
                }

                let queryStatus = queryToRun.withCString { queryPtr in
                    mysql_real_query(mysql, queryPtr, UInt(queryToRun.utf8.count))
                }

                if queryStatus != 0 {
                    continuation.finish(throwing: self.getError())
                    return
                }

                let resultPtr = mysql_use_result(mysql)

                if resultPtr == nil {
                    let fieldCount = mysql_field_count(mysql)
                    if fieldCount == 0 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: self.getError())
                    }
                    return
                }

                streamState.lock.lock()
                streamState.resultPtr = resultPtr
                streamState.lock.unlock()

                let numFields = Int(mysql_num_fields(resultPtr))
                var columns: [String] = []
                var columnTypes: [UInt32] = []
                var columnTypeNames: [String] = []
                columns.reserveCapacity(numFields)
                columnTypes.reserveCapacity(numFields)
                columnTypeNames.reserveCapacity(numFields)

                if let fields = mysql_fetch_fields(resultPtr) {
                    for i in 0..<numFields {
                        let field = fields[i]
                        if let namePtr = field.name {
                            columns.append(String(cString: namePtr))
                        } else {
                            columns.append("column_\(i)")
                        }
                        let fieldFlags = UInt(field.flags)
                        var fieldType = field.type.rawValue
                        if (fieldFlags & mysqlEnumFlag) != 0 { fieldType = 247 }
                        if (fieldFlags & mysqlSetFlag) != 0 { fieldType = 248 }
                        columnTypes.append(fieldType)
                        columnTypeNames.append(mysqlTypeToString(fields + i))
                    }
                }

                continuation.yield(.header(PluginStreamHeader(
                    columns: columns,
                    columnTypeNames: columnTypeNames,
                    estimatedRowCount: nil
                )))

                let batchSize = 5_000
                var batch: [PluginRow] = []
                batch.reserveCapacity(batchSize)
                while let rowPtr = mysql_fetch_row(resultPtr) {
                    if Task.isCancelled {
                        while mysql_fetch_row(resultPtr) != nil {}
                        streamState.lock.lock()
                        streamState.drained = true
                        streamState.lock.unlock()
                        mysql_free_result(resultPtr)
                        continuation.finish(throwing: CancellationError())
                        return
                    }

                    let lengths = mysql_fetch_lengths(resultPtr)

                    var row: [String?] = []
                    row.reserveCapacity(numFields)

                    for i in 0..<numFields {
                        if let fieldPtr = rowPtr[i] {
                            let lengthValue: UInt = lengths?[i] ?? 0
                            let length = Int(lengthValue)
                            let bufferPtr = UnsafeRawBufferPointer(start: fieldPtr, count: length)

                            if columnTypes[i] == 255 {
                                row.append(GeometryWKBParser.parse(bufferPtr))
                            } else if let str = String(bytes: bufferPtr, encoding: .utf8) {
                                row.append(str)
                            } else {
                                row.append(String(bytes: bufferPtr, encoding: .isoLatin1) ?? "")
                            }
                        } else {
                            row.append(nil)
                        }
                    }

                    batch.append(row)
                    if batch.count >= batchSize {
                        continuation.yield(.rows(batch))
                        batch.removeAll(keepingCapacity: true)
                    }
                }
                if !batch.isEmpty {
                    continuation.yield(.rows(batch))
                }

                if mysql_errno(mysql) != 0 {
                    let error = self.getError()
                    streamState.lock.lock()
                    streamState.drained = true
                    streamState.lock.unlock()
                    mysql_free_result(resultPtr)
                    continuation.finish(throwing: error)
                    return
                }

                streamState.lock.lock()
                streamState.drained = true
                streamState.lock.unlock()
                mysql_free_result(resultPtr)
                continuation.finish()
            }
        }
    }

    // MARK: - Server Information

    func serverVersion() -> String? {
        _cachedServerVersion
    }

    // MARK: - Private Helpers

    private func getError() -> MariaDBPluginError {
        guard let mysql = mysql else {
            return MariaDBPluginError.notConnected
        }

        let code = mysql_errno(mysql)
        let message: String
        if let msgPtr = mysql_error(mysql) {
            message = String(cString: msgPtr)
        } else {
            message = "Unknown error"
        }

        var sqlState: String?
        if let statePtr = mysql_sqlstate(mysql), statePtr[0] != 0 {
            sqlState = String(cString: statePtr)
        }

        return MariaDBPluginError(code: code, message: message, sqlState: sqlState)
    }

    private func getStmtError(_ stmt: UnsafeMutablePointer<MYSQL_STMT>) -> MariaDBPluginError {
        let code = mysql_stmt_errno(stmt)
        let message: String
        if let msgPtr = mysql_stmt_error(stmt) {
            message = String(cString: msgPtr)
        } else {
            message = "Unknown statement error"
        }

        var sqlState: String?
        if let statePtr = mysql_stmt_sqlstate(stmt), statePtr[0] != 0 {
            sqlState = String(cString: statePtr)
        }

        return MariaDBPluginError(code: code, message: message, sqlState: sqlState)
    }
}

// MARK: - PluginDriverError Conformance

extension MariaDBPluginError: PluginDriverError {
    var pluginErrorMessage: String { message }
    var pluginErrorCode: Int? { Int(code) }
    var pluginSqlState: String? { sqlState }
}
