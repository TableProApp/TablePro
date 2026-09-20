//
//  MariaDBPluginConnection.swift
//  MySQLDriverPlugin
//
//  Swift wrapper around libmariadb (MariaDB Connector/C)
//  Provides thread-safe, async-friendly MySQL/MariaDB connections
//

import CMariaDB
import Foundation
import os
import OSLog
import TableProPluginKit

private let logger = Logger(subsystem: "com.TablePro", category: "MariaDBPluginConnection")

// MARK: - Error Types

struct MariaDBPluginError: Error {
    let code: UInt32
    let message: String
    let sqlState: String?

    /// Set when the statement waited out the client's own socket timeout rather than the server
    /// dropping the connection. The two arrive as the same `2013`, and only this one leaves a copy
    /// of the statement running on the server, so it is never replayed.
    var outlastedSocketTimeout = false

    /// `1317 Query execution was interrupted` is what the server answers a `KILL QUERY`, so the
    /// deadline reports its own stop under the code and SQLSTATE a native statement timeout uses.
    static func queryTimeoutExceeded(seconds: Int) -> MariaDBPluginError {
        MariaDBPluginError(
            code: 1_317,
            message: String(
                format: String(localized: "Query stopped after running past the %d second query timeout"),
                seconds
            ),
            sqlState: "70100"
        )
    }

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

    /// Send to first row, measured from just before the statement goes out. Separates the server's
    /// own work from the time spent pulling the rest of the result across the wire.
    var firstRowTime: TimeInterval?
}

// MARK: - Connection Class

final class MariaDBPluginConnection: @unchecked Sendable {
    private var mysql: UnsafeMutablePointer<MYSQL>?
    private let queue = DispatchQueue(label: "com.TablePro.mariadb.plugin", qos: .userInitiated)

    /// Serial, and separate from `queue`, which the read being cancelled is sitting on. Serial so a
    /// user pressing Stop repeatedly opens one connection at a time rather than one per press.
    private let cancelQueue = DispatchQueue(label: "com.TablePro.mariadb.plugin.cancel", qos: .userInitiated)

    /// The deadline's own queue, so a statement stopped by the query timeout never waits behind a
    /// Stop the user pressed, or the other way round.
    internal let deadlineQueue = DispatchQueue(label: "com.TablePro.mariadb.plugin.deadline", qos: .userInitiated)

    internal let statementWatch = MySQLStatementWatch()

    private let host: String
    private let port: UInt32
    private let user: String
    private let password: String?
    private let database: String
    private let sslConfig: SSLConfiguration
    private let enableCleartextPlugin: Bool
    private let queryTimeoutSeconds: Int
    private let connectionEncoding: MySQLConnectionEncoding

    /// How long a read may go silent before libmariadb reports the connection lost, which is the
    /// only thing separating its own timeout from a server-side drop.
    internal let socketTimeoutSeconds: UInt32

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

    private var _flavor: MySQLServerFlavor = .mysql
    private var _killTarget: MySQLKillTarget = .threadId

    /// Set when the server has no statement timeout of its own, so the driver stops a statement
    /// that runs past the query timeout with `KILL QUERY` from a second connection.
    private var _statementDeadline: MySQLStatementDeadline?

    internal var statementDeadline: MySQLStatementDeadline? {
        stateLock.withLock { _statementDeadline }
    }

    internal func adopt(statementDeadline: MySQLStatementDeadline?) {
        stateLock.withLock { _statementDeadline = statementDeadline }
    }

    internal var flavor: MySQLServerFlavor {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _flavor
    }

    internal var killTarget: MySQLKillTarget {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _killTarget
    }

    /// Whether a `KILL QUERY` this connection sent is still sitting on the server waiting for the
    /// next statement to collect. Written from the cancel queue and the statement queue, so it lives
    /// under the same lock the flavor does.
    private var _killLatch = MySQLKillLatch()

    private func recordKillDelivered(generation: Int) {
        stateLock.withLock { _killLatch.recordDelivered(generation: generation) }
    }

    private func recordKillInterrupted(generation: Int) {
        stateLock.withLock { _killLatch.recordInterrupted(generation: generation) }
    }

    private func takeKillAbsorption() -> Bool {
        stateLock.withLock { _killLatch.takeAbsorption() }
    }

    /// Notes the server's own interruption code on the way past, so a kill this statement collected
    /// is not absorbed a second time by the next one. It never changes the error it is handed.
    private func noting(_ error: MariaDBPluginError, generation: Int) -> MariaDBPluginError {
        guard flavor.isInterruptedByKill(errno: error.code, message: error.message) else { return error }
        recordKillInterrupted(generation: generation)
        return error
    }

    /// Runs before every statement this connection sends, on the statement queue.
    ///
    /// Draining the cancel queue first is what makes the latch mean anything: a kill dispatched for
    /// the statement that just ended may not have reached the server yet, and reading the latch
    /// before it went out would let it arrive during the statement below instead.
    internal func absorbLatchedKillIfNeeded() {
        cancelQueue.sync {}
        guard takeKillAbsorption(), MySQLKillLatch.absorbsLatchedKill(flavor: flavor) else { return }
        consumePendingInterrupt()
    }

    func adopt(flavor: MySQLServerFlavor, killTarget: MySQLKillTarget) {
        stateLock.lock()
        _flavor = flavor
        _killTarget = killTarget
        stateLock.unlock()
    }

    var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isConnected
    }

    /// Whether the server says the session is inside a transaction, from the status flags in the
    /// reply to the last statement. This is the one thing about the session the server does
    /// answer for free, and it is exact where reading the statement text is a guess: measured on
    /// MySQL 8.4.11, it reports the transaction that `SET autocommit = 0` plus a plain `SELECT`
    /// opens, the one inside `/*!40101 BEGIN */`, and the one an `XA START` opens, none of which
    /// the text can show.
    var isInTransaction: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isInTransaction
    }

    private var _isInTransaction = false

    /// Whether the session runs with `NO_BACKSLASH_ESCAPES`, from the status flags of the last reply, or nil before
    /// any reply this connection read. Measured on MySQL 8.4.11 and MariaDB 11.8.9: the flag follows every session
    /// `sql_mode` change on the next OK packet, and a mode `init_connect` sets shows only from the first reply after
    /// connect, which is why it is read after the session setup statement rather than from the handshake.
    var noBackslashEscapes: Bool? {
        stateLock.withLock { _noBackslashEscapes }
    }

    private var _noBackslashEscapes: Bool?

    private func recordTransactionState(on mysql: UnsafeMutablePointer<MYSQL>) {
        var serverStatus: UInt32 = 0
        guard mariadb_get_info(mysql, MARIADB_CONNECTION_SERVER_STATUS, &serverStatus) == 0 else { return }
        let isOpen = (serverStatus & UInt32(SERVER_STATUS_IN_TRANS)) != 0
        let escapesOff = (serverStatus & UInt32(SERVER_STATUS_NO_BACKSLASH_ESCAPES)) != 0
        stateLock.lock()
        _isInTransaction = isOpen
        _noBackslashEscapes = escapesOff
        stateLock.unlock()
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
        queryTimeoutSeconds: Int = 0,
        connectionEncoding: MySQLConnectionEncoding = .utf8
    ) {
        self.host = host
        self.port = UInt32(port)
        self.user = user
        self.password = password
        self.database = database
        self.sslConfig = sslConfig
        self.enableCleartextPlugin = enableCleartextPlugin
        self.queryTimeoutSeconds = queryTimeoutSeconds
        self.connectionEncoding = connectionEncoding
        self.socketTimeoutSeconds = mysqlSocketTimeoutSeconds(forQueryTimeout: queryTimeoutSeconds)
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
            self.recordTransactionState(on: handle)
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

        var readTimeout = socketTimeoutSeconds
        mysql_options(mysql, MYSQL_OPT_READ_TIMEOUT, &readTimeout)

        var writeTimeout = socketTimeoutSeconds
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

        guard result != nil, MariaDBCharacterSet.establishSession(on: mysql, encoding: connectionEncoding) else {
            let error = readError(from: mysql)
            mysql_close(mysql)
            throw error
        }
        return mysql
    }

    private func readError(from mysql: UnsafeMutablePointer<MYSQL>) -> MariaDBPluginError {
        MariaDBPluginError(
            code: mysql_errno(mysql),
            message: mysql_error(mysql).map(decodedMessage) ?? "Unknown error",
            sqlState: sqlState(mysql_sqlstate(mysql))
        )
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
        guard let generation = cancellationGate.cancel() else { return }

        guard let mysql = mysql, let statement = killStatement(for: mysql) else { return }
        cancelQueue.async { [self] in
            killQueryOnServer(statement: statement, generation: generation)
        }
    }

    internal func killStatement(for mysql: UnsafeMutablePointer<MYSQL>) -> String? {
        killTarget.statement(threadId: mysql_thread_id(mysql))
    }

    /// The server thread this connection is on, read before a statement goes out so a kill still
    /// has somewhere to go once the handle itself is unusable.
    internal var currentThreadId: UInt {
        guard let mysql = self.mysql else { return 0 }
        return mysql_thread_id(mysql)
    }

    /// The kill has to reach the server the query is running on, which means repeating the transport
    /// the primary connection chose. Without `MYSQL_OPT_PROTOCOL` a host spelled `localhost` resolves
    /// to the default unix socket and the `port` argument is ignored, so `KILL QUERY` lands on a
    /// different server, where that thread id belongs to somebody else's session.
    ///
    /// It carries the same credentials, so it may not be a weaker channel than the primary, and it
    /// repeats the transport the primary actually got rather than the configured mode. Both TLS
    /// options are always set: left unset, the bundled connector requires TLS, so every kill against
    /// a server without TLS failed with 2026 and Stop did nothing. Reading the configured mode
    /// instead would break `.preferred`, the default, the same way: the primary succeeds through its
    /// plaintext fallback and every kill after it repeats the attempt that already failed.
    private func killQueryOnServer(statement killQuery: String, generation: Int) {
        guard let killConn = openKillConnection() else {
            logger.warning("\(killQuery, privacy: .public) could not open a connection")
            return
        }
        defer { mysql_close(killConn) }
        guard sendKill(killQuery, on: killConn) else { return }
        recordKillDelivered(generation: generation)
    }

    /// Opened outside any lock the statement's own completion waits on: against a server across the
    /// internet this is 800-1900ms of TCP, TLS and auth.
    internal func openKillConnection() -> UnsafeMutablePointer<MYSQL>? {
        let killConn = mysql_init(nil)
        guard let killConn = killConn else { return nil }

        var killTimeout: UInt32 = 5
        mysql_options(killConn, MYSQL_OPT_CONNECT_TIMEOUT, &killTimeout)
        mysql_options(killConn, MYSQL_OPT_READ_TIMEOUT, &killTimeout)
        mysql_options(killConn, MYSQL_OPT_WRITE_TIMEOUT, &killTimeout)

        var killProtocol = UInt32(MYSQL_PROTOCOL_TCP.rawValue)
        mysql_options(killConn, MYSQL_OPT_PROTOCOL, &killProtocol)

        var killAllowLocalInfile: UInt32 = 0
        mysql_options(killConn, MYSQL_OPT_LOCAL_INFILE, &killAllowLocalInfile)

        var killSSLEnforce: my_bool = effectiveSSLEnforced ? 1 : 0
        mysql_options(killConn, MYSQL_OPT_SSL_ENFORCE, &killSSLEnforce)
        var killSSLVerify: my_bool = effectiveSSLEnforced && sslConfig.verifiesCertificate ? 1 : 0
        mysql_options(killConn, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &killSSLVerify)
        if effectiveSSLEnforced {
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

        guard killResult != nil else {
            logger.warning("KILL QUERY could not connect: \(self.errorMessage(from: killConn))")
            mysql_close(killConn)
            return nil
        }
        return killConn
    }

    /// Whether the kill went out. The caller records an interrupt only on `true`, so a refused or
    /// unreachable kill never leaves a statement reported as stopped when it is still running.
    @discardableResult
    internal func sendKill(_ killQuery: String, on killConn: UnsafeMutablePointer<MYSQL>) -> Bool {
        let killStatus = killQuery.withCString { queryPtr in
            mysql_real_query(killConn, queryPtr, UInt(killQuery.utf8.count))
        }
        guard killStatus == 0 else {
            logger.warning("\(killQuery, privacy: .public) rejected: \(self.errorMessage(from: killConn))")
            return false
        }
        return true
    }

    /// Runs a statement whose only job is to test and clear the server's `KILL QUERY` flag, for a
    /// kill that arrived after the statement it was meant for had already finished. Without it the
    /// flag reaches the next statement: measured on MySQL 5.5.62, 5.6.51 and MariaDB 5.5.64, the
    /// statement after an idle kill failed with `ERROR 1317` and an `INSERT ... SELECT` inserted
    /// nothing. It costs the session its `ROW_COUNT()` and `FOUND_ROWS()`, which installing the row
    /// cap already costs.
    internal func consumePendingInterrupt() {
        guard let mysql = self.mysql else { return }
        let probe = "SELECT 1"
        _ = probe.withCString { probePtr in
            mysql_real_query(mysql, probePtr, UInt(probe.utf8.count))
        }
        if let discarded = mysql_store_result(mysql) {
            while mysql_fetch_row(discarded) != nil {}
            mysql_free_result(discarded)
        }
    }

    /// Stops a statement the client gave up on while the server kept running it. The primary handle
    /// is already unusable, so the thread id captured before the statement went out is the only way
    /// back to it.
    internal func killOrphanedStatement(threadId: UInt) {
        guard let statement = killTarget.statement(threadId: threadId) else { return }
        cancelQueue.async { [self] in
            guard let killConn = openKillConnection() else { return }
            defer { mysql_close(killConn) }
            sendKill(statement, on: killConn)
        }
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

        let probe = flavor.selectLimitProbeStatement
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
        let sessionFlavor = flavor
        let statement: String
        switch mysqlSelectLimitAction(applied: appliedSelectLimit, desired: desired) {
        case .none:
            return
        case .apply(let rows):
            captureBaselineSelectLimit(from: mysql)
            statement = sessionFlavor.selectLimitStatement(rows: rows)
        case .reset:
            statement = baselineSelectLimit.map { sessionFlavor.selectLimitStatement(rows: $0) }
                ?? sessionFlavor.selectLimitResetStatement
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

    private func isExpectedInterruption(errno: UInt32, message: String, wasTruncated: Bool) -> Bool {
        wasTruncated && flavor.isInterruptedByKill(errno: errno, message: message)
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
        try runStatement(query) { try self.runTextStatement(query, rowCap: rowCap) }
    }

    private func runTextStatement(_ query: String, rowCap: Int?) throws -> MariaDBPluginQueryResult {
        guard !isShuttingDown, let mysql = self.mysql else {
            throw MariaDBPluginError.notConnected
        }
        defer { recordTransactionState(on: mysql) }

        let generation = cancellationGate.beginQuery()
        defer { cancellationGate.endQuery(generation) }

        /// Started before the `SQL_SELECT_LIMIT` reconciliation rather than after it. That
        /// reconciliation is a round trip of its own, and leaving it outside this clock charges it
        /// to `total - firstRow`, which the breakdown presents as row transfer.
        let sentAt = Date()
        try reconcileSelectLimit(rowCap: rowCap, statement: query, on: mysql)
        if cancellationGate.isCancelled(generation) { throw CancellationError() }

        let queryStatus = query.withCString { queryPtr in
            mysql_real_query(mysql, queryPtr, UInt(query.utf8.count))
        }

        if queryStatus != 0 {
            throw noting(self.getError(), generation: generation)
        }

        let resultPtr = mysql_use_result(mysql)

        /// No result set, reported as the server sent it. A `SELECT` lands here when it projected
        /// nothing to the client (`INTO @var`, `INTO OUTFILE`, `INTO DUMPFILE`) and when a proxy
        /// answers the read with an OK packet, and an ordinary empty `SELECT` never does: measured on
        /// MySQL 5.5 to 9.7, MariaDB 11.4 and TiDB, every result set carries its columns. The driver
        /// used to guess the columns with a `DESCRIBE` of a name scraped out of the statement, which
        /// turned a statement the server had accepted into `1146 Table 'db.information_schema'
        /// doesn't exist`.
        if resultPtr == nil {
            let fieldCount = mysql_field_count(mysql)
            if fieldCount == 0 {
                let affected = mysql_affected_rows(mysql)
                let insertId = mysql_insert_id(mysql)
                return MariaDBPluginQueryResult(
                    columns: [], columnTypes: [], columnTypeNames: [],
                    rows: [], affectedRows: affected, insertId: insertId, isTruncated: false,
                    columnMeta: [],
                    firstRowTime: Date().timeIntervalSince(sentAt)
                )
            } else {
                throw self.getError()
            }
        }

        let sessionFlavor = flavor
        let columns = MariaDBCharacterSet.describeColumns(
            of: mysql_fetch_fields(resultPtr),
            count: Int(mysql_num_fields(resultPtr)),
            encoding: connectionEncoding,
            flavor: sessionFlavor
        )

        var rows: [[PluginCellValue]] = []
        rows.reserveCapacity(min(1_000, PluginRowLimits.emergencyMax))

        let maxRows = mysqlClampedRowCap(rowCap) ?? PluginRowLimits.emergencyMax
        let fetchLimit = maxRows == PluginRowLimits.emergencyMax ? maxRows : maxRows + 1
        var serverSentMore = false
        var firstRowTime: TimeInterval?

        while let rowPtr = mysql_fetch_row(resultPtr) {
            if firstRowTime == nil { firstRowTime = Date().timeIntervalSince(sentAt) }
            if cancellationGate.isCancelled(generation) {
                while mysql_fetch_row(resultPtr) != nil {}
                mysql_free_result(resultPtr)
                throw CancellationError()
            }

            if rows.count >= fetchLimit {
                serverSentMore = true
                break
            }

            rows.append(textProtocolRow(rowPtr, lengths: mysql_fetch_lengths(resultPtr), columns: columns))
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
            if !sessionFlavor.dropsIdleSessionOnKillQuery, let statement = killStatement(for: mysql) {
                killQueryOnServer(statement: statement, generation: generation)
            }
            while mysql_fetch_row(resultPtr) != nil {}
        }

        if cancellationGate.isCancelled(generation) {
            mysql_free_result(resultPtr)
            throw CancellationError()
        }

        let fetchErrno = mysql_errno(mysql)
        if fetchErrno != 0 {
            let error = noting(getError(), generation: generation)
            if !isExpectedInterruption(
                errno: fetchErrno, message: error.message, wasTruncated: outcome.serverIgnoredLimit
            ) {
                mysql_free_result(resultPtr)
                throw error
            }
        }

        mysql_free_result(resultPtr)

        if sessionFlavor.isDatabend, let affected = DatabendResultShape.affectedRowCount(columns: columns.names, rows: rows) {
            return MariaDBPluginQueryResult(
                columns: [], columnTypes: [], columnTypeNames: [],
                rows: [], affectedRows: affected, insertId: 0, isTruncated: false,
                columnMeta: [],
                firstRowTime: firstRowTime ?? Date().timeIntervalSince(sentAt)
            )
        }

        return MariaDBPluginQueryResult(
            columns: columns.names, columnTypes: columns.typeCodes, columnTypeNames: columns.typeNames,
            rows: rows, affectedRows: UInt64(rows.count), insertId: 0, isTruncated: truncated,
            columnMeta: columns.metadata,
            firstRowTime: firstRowTime ?? Date().timeIntervalSince(sentAt)
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
        columns: MySQLResultColumns,
        rowCap: Int? = nil,
        generation: Int,
        sentAt: Date
    ) throws -> (rows: [[PluginCellValue]], isTruncated: Bool, firstRowTime: TimeInterval) {
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
        /// `mysql_stmt_execute` returns once the server has answered with a header, which on an
        /// unbuffered statement can be long before the first tuple exists. Only a fetch that
        /// returns a row proves the server produced one.
        var firstRowTime: TimeInterval?

        while true {
            let fetchStatus = mysql_stmt_fetch(stmt)
            if fetchStatus == MYSQL_NO_DATA { break }
            if fetchStatus != 0, fetchStatus != MYSQL_DATA_TRUNCATED {
                throw getStmtError(stmt)
            }
            if firstRowTime == nil { firstRowTime = Date().timeIntervalSince(sentAt) }

            if cancellationGate.isCancelled(generation) {
                throw CancellationError()
            }

            if rows.count >= fetchLimit {
                serverSentMore = true
                break
            }

            if fetchStatus == MYSQL_DATA_TRUNCATED {
                var grewBuffer = false
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
                        grewBuffer = true
                        if mysql_stmt_fetch_column(stmt, &resultBinds[i], UInt32(i), 0) != 0 {
                            logger.warning("mysql_stmt_fetch_column failed for column \(i)")
                        }
                    }
                }
                if grewBuffer, mysql_stmt_bind_result(stmt, &resultBinds) != 0 {
                    throw getStmtError(stmt)
                }
            }

            rows.append(columns.row(encoding: connectionEncoding) { index in
                guard resultBinds[index].is_null?.pointee != 1 else { return nil }
                let length = Int(resultBinds[index].length?.pointee ?? 0)
                return UnsafeRawBufferPointer(start: resultBuffers[index], count: length)
            })
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

        return (
            rows: rows,
            isTruncated: outcome.isTruncated,
            firstRowTime: firstRowTime ?? Date().timeIntervalSince(sentAt)
        )
    }

    private func executeParameterizedQuerySync(
        _ query: String,
        parameters: [PluginCellValue],
        rowCap: Int? = nil
    ) throws -> MariaDBPluginQueryResult {
        guard flavor.preparesOnServer else {
            return try executeQuerySync(DatabendLiteral.inline(query, parameters: parameters), rowCap: rowCap)
        }
        return try runStatement(query) {
            try self.runPreparedStatement(query, parameters: parameters, rowCap: rowCap)
        }
    }

    private func runPreparedStatement(
        _ query: String,
        parameters: [PluginCellValue],
        rowCap: Int?
    ) throws -> MariaDBPluginQueryResult {
        guard !isShuttingDown, let mysql = self.mysql else {
            throw MariaDBPluginError.notConnected
        }
        defer { recordTransactionState(on: mysql) }

        let generation = cancellationGate.beginQuery()
        defer { cancellationGate.endQuery(generation) }

        /// Ahead of both the reconciliation and the prepare, for the reason the text path gives.
        let sentAt = Date()
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
                throw noting(getStmtError(stmt), generation: generation)
            }
        } else {
            if mysql_stmt_execute(stmt) != 0 {
                throw noting(getStmtError(stmt), generation: generation)
            }
        }
        let executedAt = Date().timeIntervalSince(sentAt)

        let fieldCount = Int(mysql_stmt_field_count(stmt))

        if fieldCount == 0 {
            let affected = mysql_stmt_affected_rows(stmt)
            let insertId = mysql_stmt_insert_id(stmt)
            return MariaDBPluginQueryResult(
                columns: [], columnTypes: [], columnTypeNames: [],
                rows: [], affectedRows: UInt64(affected), insertId: UInt64(insertId), isTruncated: false,
                columnMeta: [],
                firstRowTime: executedAt
            )
        }

        guard let metadata = mysql_stmt_result_metadata(stmt) else {
            throw MariaDBPluginError(code: 0, message: "Failed to fetch result metadata", sqlState: nil)
        }

        defer {
            mysql_free_result(metadata)
        }

        let columns = MariaDBCharacterSet.describeColumns(
            of: mysql_fetch_fields(metadata),
            count: Int(mysql_num_fields(metadata)),
            encoding: connectionEncoding,
            flavor: flavor
        )

        let fetchResult = try fetchResultSet(
            from: stmt, metadata: metadata,
            columns: columns, rowCap: rowCap, generation: generation, sentAt: sentAt
        )

        return MariaDBPluginQueryResult(
            columns: columns.names, columnTypes: columns.typeCodes, columnTypeNames: columns.typeNames,
            rows: fetchResult.rows, affectedRows: UInt64(fetchResult.rows.count),
            insertId: 0, isTruncated: fetchResult.isTruncated,
            columnMeta: columns.metadata,
            firstRowTime: fetchResult.firstRowTime
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
                do {
                    try runStatement(queryToRun) {
                        try self.streamStatement(queryToRun, continuation: continuation, abort: abort)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func streamStatement(
        _ queryToRun: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation,
        abort: PluginStreamAbort
    ) throws {
        guard !isShuttingDown, let mysql = self.mysql else {
            throw MariaDBPluginError.notConnected
        }
        defer { recordTransactionState(on: mysql) }

        let generation = cancellationGate.beginQuery()
        defer { cancellationGate.endQuery(generation) }

        guard !abort.isAborted else { return }

        try reconcileSelectLimit(rowCap: nil, statement: queryToRun, on: mysql)

        let queryStatus = queryToRun.withCString { queryPtr in
            mysql_real_query(mysql, queryPtr, UInt(queryToRun.utf8.count))
        }

        if queryStatus != 0 {
            throw noting(getError(), generation: generation)
        }

        let resultPtr = mysql_use_result(mysql)

        if resultPtr == nil {
            guard mysql_field_count(mysql) == 0 else { throw noting(getError(), generation: generation) }
            return
        }

        let columns = MariaDBCharacterSet.describeColumns(
            of: mysql_fetch_fields(resultPtr),
            count: Int(mysql_num_fields(resultPtr)),
            encoding: connectionEncoding,
            flavor: flavor
        )

        continuation.yield(.header(PluginStreamHeader(
            columns: columns.names,
            columnTypeNames: columns.typeNames,
            estimatedRowCount: nil
        )))

        let batchSize = 5_000
        var batch: [PluginRow] = []
        batch.reserveCapacity(batchSize)
        while let rowPtr = mysql_fetch_row(resultPtr) {
            if abort.isAborted || cancellationGate.isCancelled(generation) {
                /// Same shape as the capped buffered read: stop the server first, then
                /// drain what is already in flight so the connection stays usable.
                if let statement = killStatement(for: mysql) {
                    killQueryOnServer(statement: statement, generation: generation)
                }
                while mysql_fetch_row(resultPtr) != nil {}
                mysql_free_result(resultPtr)
                throw CancellationError()
            }

            batch.append(textProtocolRow(rowPtr, lengths: mysql_fetch_lengths(resultPtr), columns: columns))
            if batch.count >= batchSize {
                continuation.yield(.rows(batch))
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            continuation.yield(.rows(batch))
        }

        if mysql_errno(mysql) != 0 {
            let error = noting(getError(), generation: generation)
            mysql_free_result(resultPtr)
            throw error
        }

        mysql_free_result(resultPtr)
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
        return readError(from: mysql)
    }

    /// A killed or server-timed-out prepared fetch leaves `mysql_stmt_errno` at 0 and reports the
    /// reason on the connection handle instead: measured on MySQL 5.7.44, `fetch rc=1 stmt errno 0
    /// '' conn errno 3024`. Reading only the statement threw code 0 with an empty message, so the
    /// user was shown nothing at all.
    private func getStmtError(_ stmt: UnsafeMutablePointer<MYSQL_STMT>) -> MariaDBPluginError {
        let code = mysql_stmt_errno(stmt)
        guard code == 0, let mysql = self.mysql, mysql_errno(mysql) != 0 else {
            return MariaDBPluginError(
                code: code,
                message: mysql_stmt_error(stmt).map(decodedMessage) ?? "Unknown statement error",
                sqlState: sqlState(mysql_stmt_sqlstate(stmt))
            )
        }
        return readError(from: mysql)
    }

    private func decodedMessage(_ message: UnsafePointer<CChar>) -> String {
        mysqlSessionText(cString: message, encoding: connectionEncoding)
    }

    private func sqlState(_ state: UnsafePointer<CChar>?) -> String? {
        guard let state, state[0] != 0 else { return nil }
        return String(cString: state)
    }

    private func textProtocolRow(
        _ row: MYSQL_ROW,
        lengths: UnsafeMutablePointer<UInt>?,
        columns: MySQLResultColumns
    ) -> [PluginCellValue] {
        columns.row(encoding: connectionEncoding) { index in
            guard let value = row[index] else { return nil }
            return UnsafeRawBufferPointer(start: value, count: Int(clamping: lengths?[index] ?? 0))
        }
    }
}

// MARK: - PluginDriverError Conformance

extension MariaDBPluginError: PluginDriverError {
    var pluginErrorMessage: String { message }
    var pluginErrorCode: Int? { Int(code) }
    var pluginSqlState: String? { sqlState }
}
