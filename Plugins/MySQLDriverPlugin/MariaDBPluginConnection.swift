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
internal let mysqlNotNullFlag: UInt = 0x0001
internal let mysqlPriKeyFlag: UInt = 0x0002
internal let mysqlBinaryFlag: UInt = 0x0080
internal let mysqlEnumFlag: UInt = 0x0100
internal let mysqlAutoIncrementFlag: UInt = 0x0200
internal let mysqlSetFlag: UInt = 0x0800
internal let mysqlBinaryCharset: UInt32 = 63

private let logger = Logger(subsystem: "com.TablePro", category: "MariaDBPluginConnection")

internal func makeColumnMeta(name: String, typeName: String, flags: UInt) -> PluginColumnInfo {
    PluginColumnInfo(
        name: name,
        dataType: typeName,
        isNullable: (flags & mysqlNotNullFlag) == 0,
        isPrimaryKey: (flags & mysqlPriKeyFlag) != 0,
        identityKind: (flags & mysqlAutoIncrementFlag) != 0 ? .byDefault : nil
    )
}

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
    let rows: [[PluginCellValue]]
    let affectedRows: UInt64
    let insertId: UInt64
    let isTruncated: Bool
    let columnMeta: [PluginColumnInfo]
}

// MARK: - SSL Configuration

// MARK: - Type Mapping

func mysqlTypeToString(_ fieldPtr: UnsafePointer<MYSQL_FIELD>) -> String {
    let field = fieldPtr.pointee
    let flags = UInt(field.flags)
    let length = field.length

    // MariaDB extended metadata: detect JSON stored as LONGTEXT.
    // `MARIADB_CONST_STRING` is length-prefixed (not null-terminated), so we must read
    // exactly `attr.length` bytes. `String(cString:)` would scan past the buffer into
    // adjacent memory and intermittently fail the comparison when that memory is non-zero.
    var attr = MARIADB_CONST_STRING()
    if mariadb_field_attr(&attr, fieldPtr, MARIADB_FIELD_ATTR_FORMAT_NAME) == 0,
       let str = attr.str, attr.length > 0,
       let value = String(data: Data(bytes: str, count: Int(attr.length)), encoding: .utf8),
       value == "json" {
        return "JSON"
    }

    if (flags & mysqlEnumFlag) != 0 { return "ENUM" }
    if (flags & mysqlSetFlag) != 0 { return "SET" }

    return mariaDBTypeName(
        typeRaw: field.type.rawValue,
        flags: flags,
        charsetnr: field.charsetnr,
        length: field.length
    )
}

/// Pure mapping from raw MySQL/MariaDB field type code + flags to TablePro's
/// column-type-name string. Separated from `mysqlTypeToString` so it can be
/// unit-tested without an actual `MYSQL_FIELD` struct.
internal func mariaDBTypeName(
    typeRaw: UInt32,
    flags: UInt,
    charsetnr: UInt32,
    length: UInt
) -> String {
    // Binary flag alone is insufficient — MariaDB sets it on text columns with
    // binary collation (e.g. utf8mb4_bin for JSON). Only charset 63 is truly binary.
    let isBinary = (flags & mysqlBinaryFlag) != 0 && charsetnr == mysqlBinaryCharset

    switch typeRaw {
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
    case 253: return isBinary ? "VARBINARY" : "VARCHAR"
    case 254: return isBinary ? "BINARY" : "CHAR"
    case 255: return "GEOMETRY"
    default: return "UNKNOWN"
    }
}

// MARK: - Connection Class

final class MariaDBPluginConnection: @unchecked Sendable {
    private var mysql: UnsafeMutablePointer<MYSQL>?
    private let queue = DispatchQueue(label: "com.TablePro.mariadb.plugin", qos: .userInitiated)

    /// Serial, and separate from `queue`, which the read being cancelled is sitting on. Serial so a
    /// user pressing Stop repeatedly opens one connection at a time rather than one per press.
    private let cancelQueue = DispatchQueue(label: "com.TablePro.mariadb.plugin.cancel", qos: .userInitiated)

    private let host: String
    private let port: UInt32
    private let user: String
    private let password: String?
    private let database: String
    private let sslConfig: SSLConfiguration
    private let enableCleartextPlugin: Bool
    private let queryTimeoutSeconds: Int

    private let stateLock = NSLock()
    private let cancellationGate = PluginQueryCancellationGate()
    private var _isConnected: Bool = false
    private var _isShuttingDown: Bool = false
    private var _cachedServerVersion: String?

    /// The session's `SQL_SELECT_LIMIT` as this connection last confirmed it, `nil` while it still
    /// holds `baselineSelectLimit`. Only ever touched from `queue`, which every statement path runs on.
    private var appliedSelectLimit: UInt64?

    /// What the session held before this connection first took the variable over, so restoring it
    /// gives back a limit the server, an `init_connect` or the connection's own startup SQL had set
    /// rather than overwriting it with `DEFAULT`. Read lazily, because startup commands run after
    /// `connect()` returns. `nil` means it has not been captured, or could not be.
    private var baselineSelectLimit: UInt64?
    private var hasCapturedBaselineSelectLimit = false

    /// Whether the connection that actually succeeded negotiated TLS. `.preferred` falls back to
    /// plaintext, so the configured mode does not say what the transport ended up being, and the
    /// `KILL` connection has to repeat what worked rather than what was asked for.
    private var effectiveSSLEnforced = false

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
        sslConfig: SSLConfiguration,
        enableCleartextPlugin: Bool = false,
        queryTimeoutSeconds: Int = 0
    ) {
        self.host = host
        self.port = UInt32(port)
        self.user = user
        self.password = password
        self.database = database
        self.sslConfig = sslConfig
        self.enableCleartextPlugin = enableCleartextPlugin
        self.queryTimeoutSeconds = queryTimeoutSeconds
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
            let mode = self.sslConfig.mode
            let handle: UnsafeMutablePointer<MYSQL>
            do {
                handle = try self.attemptConnect(enforceSSL: mode != .disabled)
            } catch let error as MariaDBPluginError where mode == .preferred && MariaDBSSLClassifier.sslOnlyErrorCodes.contains(error.code) {
                logger.notice("MySQL SSL handshake failed (code \(error.code)); falling back to plaintext for .preferred mode")
                do {
                    handle = try self.attemptConnect(enforceSSL: false)
                } catch let fallbackError as MariaDBPluginError {
                    if let sslError = MariaDBSSLClassifier.classifySSLError(code: fallbackError.code, message: fallbackError.message) {
                        throw sslError
                    }
                    throw fallbackError
                }
            } catch let error as MariaDBPluginError {
                if let sslError = MariaDBSSLClassifier.classifySSLError(code: error.code, message: error.message) {
                    throw sslError
                }
                throw error
            }

            if let versionPtr = mysql_get_server_info(handle) {
                self._cachedServerVersion = String(cString: versionPtr)
            }

            self.effectiveSSLEnforced = mysql_get_ssl_cipher(handle) != nil
            self.appliedSelectLimit = nil
            self.baselineSelectLimit = nil
            self.hasCapturedBaselineSelectLimit = false

            self.stateLock.lock()
            self.mysql = handle
            self._isConnected = true
            self.stateLock.unlock()
        }
    }

    private func attemptConnect(enforceSSL: Bool) throws -> UnsafeMutablePointer<MYSQL> {
        guard let mysql = mysql_init(nil) else {
            throw MariaDBPluginError.initFailed
        }

        var reconnect: my_bool = 0
        mysql_options(mysql, MYSQL_OPT_RECONNECT, &reconnect)

        var timeout: UInt32 = 10
        mysql_options(mysql, MYSQL_OPT_CONNECT_TIMEOUT, &timeout)

        var readTimeout = mysqlSocketTimeoutSeconds(forQueryTimeout: queryTimeoutSeconds)
        mysql_options(mysql, MYSQL_OPT_READ_TIMEOUT, &readTimeout)

        var writeTimeout = mysqlSocketTimeoutSeconds(forQueryTimeout: queryTimeoutSeconds)
        mysql_options(mysql, MYSQL_OPT_WRITE_TIMEOUT, &writeTimeout)

        var protocol_tcp = UInt32(MYSQL_PROTOCOL_TCP.rawValue)
        mysql_options(mysql, MYSQL_OPT_PROTOCOL, &protocol_tcp)

        var allowLocalInfile: UInt32 = 0
        mysql_options(mysql, MYSQL_OPT_LOCAL_INFILE, &allowLocalInfile)

        var sslEnforce: my_bool = enforceSSL ? 1 : 0
        mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &sslEnforce)

        var sslVerify: my_bool = sslConfig.verifiesCertificate ? 1 : 0
        mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &sslVerify)

        if sslConfig.verifiesCertificate, !sslConfig.caCertificatePath.isEmpty {
            _ = sslConfig.caCertificatePath.withCString { mysql_options(mysql, MYSQL_OPT_SSL_CA, $0) }
        }
        if !sslConfig.clientCertificatePath.isEmpty {
            _ = sslConfig.clientCertificatePath.withCString { mysql_options(mysql, MYSQL_OPT_SSL_CERT, $0) }
        }
        if !sslConfig.clientKeyPath.isEmpty {
            _ = sslConfig.clientKeyPath.withCString { mysql_options(mysql, MYSQL_OPT_SSL_KEY, $0) }
        }

        mysql_options(mysql, MYSQL_SET_CHARSET_NAME, "utf8mb4")

        if enableCleartextPlugin {
            var enableCleartext: my_bool = 1
            mysql_options(mysql, MYSQL_ENABLE_CLEARTEXT_PLUGIN, &enableCleartext)
        }

        let dbToUse = database.isEmpty ? nil : database
        let passToUse = password

        let result: UnsafeMutablePointer<MYSQL>?
        if let db = dbToUse, let pass = passToUse {
            result = host.withCString { hostPtr in
                user.withCString { userPtr in
                    pass.withCString { passPtr in
                        db.withCString { dbPtr in
                            mysql_real_connect(mysql, hostPtr, userPtr, passPtr, dbPtr, port, nil, 0)
                        }
                    }
                }
            }
        } else if let db = dbToUse {
            result = host.withCString { hostPtr in
                user.withCString { userPtr in
                    db.withCString { dbPtr in
                        mysql_real_connect(mysql, hostPtr, userPtr, nil, dbPtr, port, nil, 0)
                    }
                }
            }
        } else if let pass = passToUse {
            result = host.withCString { hostPtr in
                user.withCString { userPtr in
                    pass.withCString { passPtr in
                        mysql_real_connect(mysql, hostPtr, userPtr, passPtr, nil, port, nil, 0)
                    }
                }
            }
        } else {
            result = host.withCString { hostPtr in
                user.withCString { userPtr in
                    mysql_real_connect(mysql, hostPtr, userPtr, nil, nil, port, nil, 0)
                }
            }
        }

        if result == nil {
            let error = readError(from: mysql)
            mysql_close(mysql)
            throw error
        }
        return mysql
    }

    private func readError(from mysql: UnsafeMutablePointer<MYSQL>) -> MariaDBPluginError {
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

    /// Stop reaches the server over a second connection, and building one is a TCP connect, a TLS
    /// handshake and an auth exchange. `DatabaseManager.cancelRunningQuery` calls this synchronously
    /// from the main actor on purpose, because the user is waiting, so the connect cannot happen
    /// there: against a host that has stopped answering, which is exactly when someone presses Stop,
    /// `mysql_real_connect` blocks for the full five-second `MYSQL_OPT_CONNECT_TIMEOUT`.
    ///
    /// The half the caller needs is the gate, which is already synchronous: it is what makes the
    /// in-flight read give up. The kill is server-side cleanup and carries only a thread id, no
    /// handle, so it is safe to finish on its own queue.
    func cancelCurrentQuery() {
        guard cancellationGate.cancel() != nil else { return }

        guard let mysql = mysql else { return }
        let threadId = mysql_thread_id(mysql)
        cancelQueue.async { [self] in
            killQueryOnServer(threadId: threadId)
        }
    }

    /// The kill has to reach the server the query is running on, which means repeating the transport
    /// the primary connection chose. Without `MYSQL_OPT_PROTOCOL` a host spelled `localhost` resolves
    /// to the default unix socket and the `port` argument is ignored, so `KILL QUERY` lands on a
    /// different server, where that thread id belongs to somebody else's session.
    ///
    /// It carries the same credentials, so it may not be a weaker channel than the primary. TLS is
    /// enforced whenever the primary's own connection negotiated it, and left unset otherwise so the
    /// connector can still negotiate opportunistically; `MYSQL_OPT_SSL_ENFORCE` set to 0 does not mean
    /// "no preference", it turns TLS off outright. Reading the configured mode instead of what the
    /// connection actually got would break `.preferred`, the default, on a server with no TLS: the
    /// primary succeeds through its plaintext fallback and every kill after it repeats the attempt
    /// that already failed.
    private func killQueryOnServer(threadId: UInt) {
        guard threadId > 0 else { return }

        let killConn = mysql_init(nil)
        guard let killConn = killConn else { return }

        var killTimeout: UInt32 = 5
        mysql_options(killConn, MYSQL_OPT_CONNECT_TIMEOUT, &killTimeout)
        mysql_options(killConn, MYSQL_OPT_READ_TIMEOUT, &killTimeout)
        mysql_options(killConn, MYSQL_OPT_WRITE_TIMEOUT, &killTimeout)

        var killProtocol = UInt32(MYSQL_PROTOCOL_TCP.rawValue)
        mysql_options(killConn, MYSQL_OPT_PROTOCOL, &killProtocol)

        var killAllowLocalInfile: UInt32 = 0
        mysql_options(killConn, MYSQL_OPT_LOCAL_INFILE, &killAllowLocalInfile)

        if effectiveSSLEnforced {
            var killSSLEnforce: my_bool = 1
            mysql_options(killConn, MYSQL_OPT_SSL_ENFORCE, &killSSLEnforce)
            var killSSLVerify: my_bool = sslConfig.verifiesCertificate ? 1 : 0
            mysql_options(killConn, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &killSSLVerify)
            if sslConfig.verifiesCertificate, !sslConfig.caCertificatePath.isEmpty {
                _ = sslConfig.caCertificatePath.withCString { mysql_options(killConn, MYSQL_OPT_SSL_CA, $0) }
            }
            if !sslConfig.clientCertificatePath.isEmpty {
                _ = sslConfig.clientCertificatePath.withCString { mysql_options(killConn, MYSQL_OPT_SSL_CERT, $0) }
            }
            if !sslConfig.clientKeyPath.isEmpty {
                _ = sslConfig.clientKeyPath.withCString { mysql_options(killConn, MYSQL_OPT_SSL_KEY, $0) }
            }
        }

        if enableCleartextPlugin {
            var killEnableCleartext: my_bool = 1
            mysql_options(killConn, MYSQL_ENABLE_CLEARTEXT_PLUGIN, &killEnableCleartext)
        }

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
            let killStatus = killQuery.withCString { queryPtr in
                mysql_real_query(killConn, queryPtr, UInt(killQuery.utf8.count))
            }
            if killStatus != 0 {
                logger.warning("KILL QUERY \(threadId) rejected: \(self.errorMessage(from: killConn))")
            }
        } else {
            logger.warning("KILL QUERY \(threadId) could not connect: \(self.errorMessage(from: killConn))")
        }

        mysql_close(killConn)
    }

    private func errorMessage(from mysql: UnsafeMutablePointer<MYSQL>) -> String {
        let code = mysql_errno(mysql)
        guard let messagePtr = mysql_error(mysql) else { return "error \(code)" }
        return "\(code) \(String(cString: messagePtr))"
    }

    // MARK: - Server-Side Row Cap

    /// `SQL_SELECT_LIMIT` is session state, so it is reconciled before every statement rather than
    /// left set: it bounds any later `SELECT` on this connection, `information_schema` and
    /// `SHOW FULL COLUMNS` included. The cache moves only once the server confirms the change, so a
    /// failed reset is something the next statement retries rather than a silent truncation.
    /// Taken the first time this connection is about to own the variable, not at connect: the
    /// connection's startup commands run after `connect()` returns, so a `SET SESSION
    /// SQL_SELECT_LIMIT` among them would otherwise be captured too late to be restored and lost.
    private func captureBaselineSelectLimit(from mysql: UnsafeMutablePointer<MYSQL>) {
        guard !hasCapturedBaselineSelectLimit else { return }
        hasCapturedBaselineSelectLimit = true

        let probe = mysqlSelectLimitProbeStatement()
        let status = probe.withCString { probePtr in
            mysql_real_query(mysql, probePtr, UInt(probe.utf8.count))
        }
        guard status == 0, let result = mysql_store_result(mysql) else { return }
        defer { mysql_free_result(result) }
        guard let row = mysql_fetch_row(result), let valuePtr = row[0] else { return }
        baselineSelectLimit = UInt64(String(cString: valuePtr))
    }

    private func reconcileSelectLimit(
        rowCap: Int?,
        statement query: String,
        on mysql: UnsafeMutablePointer<MYSQL>
    ) throws {
        /// Only trustworthy while this connection holds no limit of its own: a statement misread as
        /// single-row would otherwise keep a stale cap installed and end early under it, and the
        /// client would compare that short count against the current cap and call it complete.
        if appliedSelectLimit == nil, rowCap != nil, mysqlStatementReturnsAtMostOneRow(query) {
            return
        }

        let desired = mysqlClampedRowCap(rowCap).map { mysqlSelectLimitRows(forRowCap: $0) }
        let statement: String
        switch mysqlSelectLimitAction(applied: appliedSelectLimit, desired: desired) {
        case .none:
            return
        case .apply(let rows):
            captureBaselineSelectLimit(from: mysql)
            statement = mysqlSelectLimitStatement(rows: rows)
        case .reset:
            statement = baselineSelectLimit.map { mysqlSelectLimitStatement(rows: $0) }
                ?? mysqlSelectLimitResetStatement()
        }

        let status = statement.withCString { statementPtr in
            mysql_real_query(mysql, statementPtr, UInt(statement.utf8.count))
        }
        if let discarded = mysql_store_result(mysql) {
            mysql_free_result(discarded)
        }
        guard status == 0 else {
            let error = getError()
            logger.warning("SQL_SELECT_LIMIT not reconciled: \(self.errorMessage(from: mysql))")
            /// Failing to install a cap costs only the client-side fallback. Failing to move one that
            /// is already installed would run the statement under a stricter limit than it asked for
            /// and report the short result as complete.
            guard appliedSelectLimit == nil else { throw error }
            return
        }
        appliedSelectLimit = desired
    }

    private static func isExpectedInterruption(errno: UInt32, wasTruncated: Bool) -> Bool {
        wasTruncated && errno == UInt32(ER_QUERY_INTERRUPTED)
    }

    // MARK: - Query Execution

    func executeQuery(_ query: String, rowCap: Int? = nil) async throws -> MariaDBPluginQueryResult {
        let queryToRun = String(query)

        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown else { throw MariaDBPluginError.notConnected }
            return try executeQuerySync(queryToRun, rowCap: rowCap)
        }
    }

    func executeParameterizedQuery(
        _ query: String,
        parameters: [PluginCellValue],
        rowCap: Int? = nil
    ) async throws -> MariaDBPluginQueryResult {
        let queryToRun = String(query)
        let params = parameters

        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown else { throw MariaDBPluginError.notConnected }
            return try executeParameterizedQuerySync(queryToRun, parameters: params, rowCap: rowCap)
        }
    }

    private func executeQuerySync(_ query: String, rowCap: Int? = nil) throws -> MariaDBPluginQueryResult {
        guard !isShuttingDown, let mysql = self.mysql else {
            throw MariaDBPluginError.notConnected
        }

        let generation = cancellationGate.beginQuery()
        defer { cancellationGate.endQuery(generation) }

        try reconcileSelectLimit(rowCap: rowCap, statement: query, on: mysql)
        if cancellationGate.isCancelled(generation) { throw CancellationError() }

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
                    rows: [], affectedRows: affected, insertId: insertId, isTruncated: false,
                    columnMeta: []
                )
            } else {
                throw self.getError()
            }
        }

        let numFields = Int(mysql_num_fields(resultPtr))
        var columns: [String] = []
        var columnTypes: [UInt32] = []
        var columnTypeNames: [String] = []
        var columnIsBinary: [Bool] = []
        var columnMeta: [PluginColumnInfo] = []
        columns.reserveCapacity(numFields)
        columnTypes.reserveCapacity(numFields)
        columnTypeNames.reserveCapacity(numFields)
        columnIsBinary.reserveCapacity(numFields)
        columnMeta.reserveCapacity(numFields)

        if let fields = mysql_fetch_fields(resultPtr) {
            for i in 0..<numFields {
                let field = fields[i]
                let columnName = field.name.map { String(cString: $0) } ?? "column_\(i)"
                columns.append(columnName)
                let fieldFlags = UInt(field.flags)
                var fieldType = field.type.rawValue
                if (fieldFlags & mysqlEnumFlag) != 0 { fieldType = 247 }
                if (fieldFlags & mysqlSetFlag) != 0 { fieldType = 248 }
                columnTypes.append(fieldType)
                let typeName = mysqlTypeToString(fields + i)
                columnTypeNames.append(typeName)
                columnIsBinary.append(
                    MariaDBFieldClassifier.isBinary(
                        typeRaw: field.type.rawValue,
                        charset: field.charsetnr
                    )
                )
                columnMeta.append(makeColumnMeta(name: columnName, typeName: typeName, flags: fieldFlags))
            }
        }

        var rows: [[PluginCellValue]] = []
        rows.reserveCapacity(min(1_000, PluginRowLimits.emergencyMax))

        let maxRows = mysqlClampedRowCap(rowCap) ?? PluginRowLimits.emergencyMax
        let fetchLimit = maxRows == PluginRowLimits.emergencyMax ? maxRows : maxRows + 1
        var serverSentMore = false

        while let rowPtr = mysql_fetch_row(resultPtr) {
            if cancellationGate.isCancelled(generation) {
                while mysql_fetch_row(resultPtr) != nil {}
                mysql_free_result(resultPtr)
                throw CancellationError()
            }

            if rows.count >= fetchLimit {
                serverSentMore = true
                break
            }

            let lengths = mysql_fetch_lengths(resultPtr)

            var row: [PluginCellValue] = []
            row.reserveCapacity(numFields)

            for i in 0..<numFields {
                if let fieldPtr = rowPtr[i] {
                    let length = Int(clamping: lengths?[i] ?? 0)
                    let bufferPtr = UnsafeRawBufferPointer(start: fieldPtr, count: length)

                    if columnTypes[i] == 255 {
                        row.append(.text(GeometryWKBParser.parse(bufferPtr)))
                    } else if MariaDBFieldClassifier.isBit(typeRaw: columnTypes[i]) {
                        row.append(.text(MariaDBFieldClassifier.bitFieldToString(bufferPtr)))
                    } else if columnIsBinary[i] {
                        row.append(.bytes(Data(bufferPtr)))
                    } else if let str = String(bytes: bufferPtr, encoding: .utf8) {
                        row.append(.text(str))
                    } else {
                        row.append(.text(String(bytes: bufferPtr, encoding: .isoLatin1) ?? ""))
                    }
                } else {
                    row.append(.null)
                }
            }
            rows.append(row)
        }

        let outcome = mysqlBoundedFetchOutcome(
            fetchedRows: rows.count,
            rowCap: maxRows,
            serverSentMore: serverSentMore
        )
        let truncated = outcome.isTruncated
        if truncated {
            logger.warning("Result set truncated at \(maxRows) rows")
            rows.removeLast(rows.count - outcome.keptRows)
        }
        if outcome.serverIgnoredLimit {
            killQueryOnServer(threadId: mysql_thread_id(mysql))
            while mysql_fetch_row(resultPtr) != nil {}
        }

        if cancellationGate.isCancelled(generation) {
            mysql_free_result(resultPtr)
            throw CancellationError()
        }

        let fetchErrno = mysql_errno(mysql)
        if fetchErrno != 0, !Self.isExpectedInterruption(errno: fetchErrno, wasTruncated: outcome.serverIgnoredLimit) {
            let error = getError()
            mysql_free_result(resultPtr)
            throw error
        }

        mysql_free_result(resultPtr)

        return MariaDBPluginQueryResult(
            columns: columns, columnTypes: columnTypes, columnTypeNames: columnTypeNames,
            rows: rows, affectedRows: UInt64(rows.count), insertId: 0, isTruncated: truncated,
            columnMeta: columnMeta
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
        _ parameters: [PluginCellValue],
        toStatement stmt: UnsafeMutablePointer<MYSQL_STMT>
    ) throws -> ParameterBindings {
        let paramCount = parameters.count
        var binds: [MYSQL_BIND] = Array(repeating: MYSQL_BIND(), count: paramCount)
        var buffers: [UnsafeMutableRawPointer?] = []

        for (index, param) in parameters.enumerated() {
            switch param {
            case .null:
                binds[index].buffer_type = MYSQL_TYPE_NULL
                binds[index].is_null = UnsafeMutablePointer<my_bool>.allocate(capacity: 1)
                binds[index].is_null?.pointee = 1

            case .text(let stringValue):
                let data = stringValue.data(using: .utf8) ?? Data()
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 1)
                if !data.isEmpty {
                    data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
                }

                binds[index].buffer_type = MYSQL_TYPE_STRING
                binds[index].buffer = buffer
                binds[index].buffer_length = UInt(data.count)
                binds[index].length = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
                binds[index].length?.pointee = UInt(data.count)
                binds[index].is_null = UnsafeMutablePointer<my_bool>.allocate(capacity: 1)
                binds[index].is_null?.pointee = 0

                buffers.append(buffer)

            case .bytes(let data):
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 1)
                if !data.isEmpty {
                    data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
                }

                binds[index].buffer_type = MYSQL_TYPE_LONG_BLOB
                binds[index].buffer = buffer
                binds[index].buffer_length = UInt(data.count)
                binds[index].length = UnsafeMutablePointer<UInt>.allocate(capacity: 1)
                binds[index].length?.pointee = UInt(data.count)
                binds[index].is_null = UnsafeMutablePointer<my_bool>.allocate(capacity: 1)
                binds[index].is_null?.pointee = 0

                buffers.append(buffer)
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
        columnTypeNames: [String],
        columnIsBinary: [Bool],
        rowCap: Int? = nil,
        generation: Int
    ) throws -> (rows: [[PluginCellValue]], isTruncated: Bool) {
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

        var rows: [[PluginCellValue]] = []
        let maxRows = mysqlClampedRowCap(rowCap) ?? PluginRowLimits.emergencyMax
        let fetchLimit = maxRows == PluginRowLimits.emergencyMax ? maxRows : maxRows + 1
        var serverSentMore = false

        while true {
            let fetchStatus = mysql_stmt_fetch(stmt)
            if fetchStatus == MYSQL_NO_DATA { break }
            if fetchStatus != 0, fetchStatus != MYSQL_DATA_TRUNCATED {
                throw getStmtError(stmt)
            }

            if cancellationGate.isCancelled(generation) {
                throw CancellationError()
            }

            if rows.count >= fetchLimit {
                serverSentMore = true
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

            var row: [PluginCellValue] = []
            for i in 0..<numFields {
                if resultBinds[i].is_null?.pointee == 1 {
                    row.append(.null)
                } else {
                    let length = Int(resultBinds[i].length?.pointee ?? 0)
                    let buffer = resultBuffers[i].assumingMemoryBound(to: UInt8.self)
                    let data = Data(bytes: buffer, count: length)
                    if MariaDBFieldClassifier.isBit(typeRaw: columnTypes[i]) {
                        row.append(.text(MariaDBFieldClassifier.bitFieldToString(data)))
                    } else if columnIsBinary[i] {
                        row.append(.bytes(data))
                    } else if let str = String(data: data, encoding: .utf8) {
                        row.append(.text(str))
                    } else {
                        row.append(.text(String(data: data, encoding: .isoLatin1) ?? ""))
                    }
                }
            }
            rows.append(row)
        }

        let outcome = mysqlBoundedFetchOutcome(
            fetchedRows: rows.count,
            rowCap: maxRows,
            serverSentMore: serverSentMore
        )
        if outcome.isTruncated {
            logger.warning("Prepared statement result truncated at \(maxRows) rows")
            rows.removeLast(rows.count - outcome.keptRows)
        }

        return (rows: rows, isTruncated: outcome.isTruncated)
    }

    private func executeParameterizedQuerySync(
        _ query: String,
        parameters: [PluginCellValue],
        rowCap: Int? = nil
    ) throws -> MariaDBPluginQueryResult {
        guard !isShuttingDown, let mysql = self.mysql else {
            throw MariaDBPluginError.notConnected
        }

        let generation = cancellationGate.beginQuery()
        defer { cancellationGate.endQuery(generation) }

        try reconcileSelectLimit(rowCap: rowCap, statement: query, on: mysql)
        if cancellationGate.isCancelled(generation) { throw CancellationError() }

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
                rows: [], affectedRows: UInt64(affected), insertId: UInt64(insertId), isTruncated: false,
                columnMeta: []
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
        var columnIsBinary: [Bool] = []
        var columnMeta: [PluginColumnInfo] = []
        let numFields = Int(mysql_num_fields(metadata))

        if let fields = mysql_fetch_fields(metadata) {
            for i in 0..<numFields {
                let field = fields[i]
                let columnName = field.name.map { String(cString: $0) } ?? "column_\(i)"
                columns.append(columnName)
                let fieldFlags = UInt(field.flags)
                var fieldType = field.type.rawValue
                if (fieldFlags & mysqlEnumFlag) != 0 { fieldType = 247 }
                if (fieldFlags & mysqlSetFlag) != 0 { fieldType = 248 }
                columnTypes.append(fieldType)
                let typeName = mysqlTypeToString(fields + i)
                columnTypeNames.append(typeName)
                columnIsBinary.append(
                    MariaDBFieldClassifier.isBinary(
                        typeRaw: field.type.rawValue,
                        charset: field.charsetnr
                    )
                )
                columnMeta.append(makeColumnMeta(name: columnName, typeName: typeName, flags: fieldFlags))
            }
        }

        let fetchResult = try fetchResultSet(
            from: stmt, metadata: metadata,
            columns: columns, columnTypes: columnTypes, columnTypeNames: columnTypeNames,
            columnIsBinary: columnIsBinary, rowCap: rowCap, generation: generation
        )

        return MariaDBPluginQueryResult(
            columns: columns, columnTypes: columnTypes, columnTypeNames: columnTypeNames,
            rows: fetchResult.rows, affectedRows: UInt64(fetchResult.rows.count),
            insertId: 0, isTruncated: fetchResult.isTruncated,
            columnMeta: columnMeta
        )
    }

    // MARK: - Streaming Query

    func streamQuery(_ query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let queryToRun = String(query)

        /// The drain belongs to the producer. Enqueued from `onTermination` it would sit behind the
        /// producer on this one serial queue and run only after the whole result had been read,
        /// which is why the abort is a polled flag instead.
        return PluginRowStream.make { continuation, abort in
            self.queue.async { [self] in
                guard !isShuttingDown, let mysql = self.mysql else {
                    continuation.finish(throwing: MariaDBPluginError.notConnected)
                    return
                }

                let generation = cancellationGate.beginQuery()
                defer { cancellationGate.endQuery(generation) }

                guard !abort.isAborted else {
                    continuation.finish()
                    return
                }

                do {
                    try reconcileSelectLimit(rowCap: nil, statement: queryToRun, on: mysql)
                } catch {
                    continuation.finish(throwing: error)
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

                let numFields = Int(mysql_num_fields(resultPtr))
                var columns: [String] = []
                var columnTypes: [UInt32] = []
                var columnTypeNames: [String] = []
                var columnIsBinary: [Bool] = []
                columns.reserveCapacity(numFields)
                columnTypes.reserveCapacity(numFields)
                columnTypeNames.reserveCapacity(numFields)
                columnIsBinary.reserveCapacity(numFields)

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
                        columnIsBinary.append(
                            MariaDBFieldClassifier.isBinary(
                                typeRaw: field.type.rawValue,
                                charset: field.charsetnr
                            )
                        )
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
                    if abort.isAborted || cancellationGate.isCancelled(generation) {
                        /// Same shape as the capped buffered read: stop the server first, then
                        /// drain what is already in flight so the connection stays usable.
                        killQueryOnServer(threadId: mysql_thread_id(mysql))
                        while mysql_fetch_row(resultPtr) != nil {}
                        mysql_free_result(resultPtr)
                        continuation.finish(throwing: CancellationError())
                        return
                    }

                    let lengths = mysql_fetch_lengths(resultPtr)

                    var row: [PluginCellValue] = []
                    row.reserveCapacity(numFields)

                    for i in 0..<numFields {
                        if let fieldPtr = rowPtr[i] {
                            let length = Int(clamping: lengths?[i] ?? 0)
                            let bufferPtr = UnsafeRawBufferPointer(start: fieldPtr, count: length)

                            if columnTypes[i] == 255 {
                                row.append(.text(GeometryWKBParser.parse(bufferPtr)))
                            } else if MariaDBFieldClassifier.isBit(typeRaw: columnTypes[i]) {
                                row.append(.text(MariaDBFieldClassifier.bitFieldToString(bufferPtr)))
                            } else if columnIsBinary[i] {
                                row.append(.bytes(Data(bufferPtr)))
                            } else if let str = String(bytes: bufferPtr, encoding: .utf8) {
                                row.append(.text(str))
                            } else {
                                row.append(.text(String(bytes: bufferPtr, encoding: .isoLatin1) ?? ""))
                            }
                        } else {
                            row.append(.null)
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
                    mysql_free_result(resultPtr)
                    continuation.finish(throwing: error)
                    return
                }

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
