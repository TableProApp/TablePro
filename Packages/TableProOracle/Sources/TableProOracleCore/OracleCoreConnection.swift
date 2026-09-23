import Foundation
import Logging
import NIOCore
import NIOSSL
import OracleNIO
import OSLog

private let osLogger = Logger(subsystem: "com.TablePro", category: "OracleCoreConnection")

/// Whether the caller now owns the channel, or how long somebody else has held it.
internal enum QueryGateTurn: Sendable, Equatable {
    case acquired
    case busy(for: Duration)
}

/// What a health check should do with the turn it was given.
internal enum OraclePingDecision: Sendable, Equatable {
    /// The probe owns the channel and may run, and may close it if it gets no answer.
    case probe
    /// Somebody else is using the channel, which answers the question better than a probe could.
    case reportAlive
    /// Nothing has moved on the channel for longer than any statement is allowed to run.
    case reportWedged

    static func of(_ turn: QueryGateTurn, wedgedAfter: Duration) -> OraclePingDecision {
        switch turn {
        case .acquired:
            return .probe
        case .busy(let held):
            return held > wedgedAfter ? .reportWedged : .reportAlive
        }
    }
}

/// OracleNIO does not support concurrent queries on a single connection.
/// Sending a second statement while the first stream is active corrupts the
/// state machine. This actor serializes all executeQuery calls.
///
/// Holding the gate is what gives a task the right to close the channel, so the gate also
/// records when the channel last went from idle to busy. A probe that cannot take a turn can
/// then tell "somebody is using this, which answers the question better than I could" from
/// "somebody has been stuck on this for longer than any statement is allowed to run".
internal actor QueryGate {
    private var heldSince: ContinuousClock.Instant?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if heldSince == nil {
            heldSince = .now
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func takeTurnIfFree() -> QueryGateTurn {
        guard let heldSince else {
            self.heldSince = .now
            return .acquired
        }
        return .busy(for: .now - heldSince)
    }

    func release() {
        if !waiters.isEmpty {
            heldSince = .now
            waiters.removeFirst().resume()
        } else {
            heldSince = nil
        }
    }
}

private actor UnsupportedTypeWarner {
    private var seen: Set<String> = []

    func warnIfNew(_ typeName: String) -> Bool {
        guard !seen.contains(typeName) else { return false }
        seen.insert(typeName)
        return true
    }
}

public final class OracleCoreConnection: @unchecked Sendable {
    private static let connectionCounter = OSAllocatedUnfairLock(initialState: 0)
    private static let pingTimeoutSeconds: Double = 10
    /// How far behind the driver's own login deadline the app's backstop sits. The
    /// driver ends a stalled handshake itself and names the phase it stalled in, so
    /// the backstop only has to catch a driver that never returns at all.
    private static let loginTimeoutGraceSeconds: Double = 5

    private let options: OracleConnectionOptions
    private let queryGate = QueryGate()
    private let unsupportedWarner = UnsupportedTypeWarner()
    private let nioLogger = Logging.Logger(label: "com.TablePro.oracle-nio")

    /// Restoring a replaced session's settings writes nothing, so it neither commits nor joins a transaction.
    private static let sessionSetupOptions = StatementOptions(autoCommit: false)

    private struct LockedState: Sendable {
        var isConnected = false
        var hasEverConnected = false
        var nioConnection: OracleNIO.OracleConnection?
        var sessionID = 0
        var transaction = OracleSessionTransaction()
        var queryTimeoutSeconds = 0
        var sessionSchema: String?
        var capturesServerOutput = false
        var close = OracleCloseRecord()
        var serverRelease: OracleServerRelease?
    }

    private let state = OSAllocatedUnfairLock(initialState: LockedState())

    public var isConnected: Bool {
        state.withLock { $0.isConnected }
    }

    /// The release the server reported in its login reply, or nil before the first login. It outlives a dropped
    /// channel, because the redial that replaces the channel reaches the same server.
    public var serverRelease: OracleServerRelease? {
        state.withLock { $0.serverRelease }
    }

    public init(options: OracleConnectionOptions) {
        self.options = options
    }

    // MARK: - Connection

    public func connect() async throws {
        let identifier = options.identifier
        let service: OracleServiceMethod = options.identifierMode == .sid
            ? .sid(identifier)
            : .serviceName(identifier)
        let tls = try OracleTLSMapper.tls(for: options.tls)
        var configuration = OracleNIO.OracleConnection.Configuration(
            host: options.host,
            port: options.port,
            service: service,
            username: options.user,
            password: options.password,
            tls: tls
        )
        configuration.mode = Self.authenticationMode(for: options.role)
        configuration.nativeNetworkEncryption = Self.encryptionLevel(for: options.networkEncryption)
        // The driver owns the channel, so it is the only thing that can end a login the
        // server has stopped answering, and it names the handshake phase when it does.
        // The wrapper below stays a grace period behind it as a backstop for a driver
        // that never returns at all.
        configuration.options.loginTimeout = .milliseconds(
            Int64((options.loginTimeoutSeconds * 1_000).rounded())
        )
        let connectConfig = configuration
        let connectLogger = nioLogger

        let connectionId = Self.connectionCounter.withLock { counter -> Int in
            counter += 1
            return counter
        }

        let attempt = OSAllocatedUnfairLock(initialState: false)

        do {
            let connection = try await withOracleTimeout(
                seconds: options.loginTimeoutSeconds + Self.loginTimeoutGraceSeconds,
                onTimeout: { attempt.withLock { $0 = true } }
            ) {
                let connection = try await OracleNIO.OracleConnection.connect(
                    configuration: connectConfig,
                    id: connectionId,
                    logger: connectLogger
                )
                // A connect that lands after the backstop fired has already been given
                // up on, and nothing downstream will ever see this handle. It closes its
                // own socket rather than leaking one per abandoned attempt.
                guard !attempt.withLock({ $0 }) else {
                    try? await connection.close()
                    osLogger.notice(
                        "Closed the Oracle connection: \(OracleDisconnectReason.abandonedLoginAttempt.logDescription, privacy: .public)"
                    )
                    throw OracleCoreError.loginTimedOut
                }
                return connection
            }

            let release = OracleServerRelease(major: connection.serverVersion.majorDatabaseReleaseNumber)

            /// A dial the app gave up on while it was in flight has nowhere to land: the plugin
            /// dropped this connection and built another, so installing the handle here would
            /// leave a session open on the server that nothing can reach or close.
            let adopted = state.withLock { current -> Bool in
                guard current.close.allowsReconnect else { return false }
                current.nioConnection = connection
                current.sessionID = connectionId
                current.isConnected = true
                current.hasEverConnected = true
                current.serverRelease = release
                current.close.clearOnConnect()
                return true
            }

            guard adopted else {
                try? await connection.close()
                osLogger.notice("Closed an Oracle connection that finished dialing after the app let it go")
                throw OracleCoreError.notConnected
            }

            osLogger.debug("Connected to Oracle \(self.options.host, privacy: .public):\(self.options.port, privacy: .public)")
        } catch is OracleTimeoutError {
            osLogger.error("Oracle login handshake timed out after \(self.options.loginTimeoutSeconds, privacy: .public)s")
            throw OracleCoreError.loginTimedOut
        } catch let sqlError as OracleSQLError {
            throw connectError(from: sqlError)
        } catch let nioSslError as NIOSSLError {
            let detail = String(describing: nioSslError)
            let kind = OracleSSLClassifier.classifyTLSFailure(detail) ?? .unknown
            osLogger.error("Oracle TLS error: \(String(describing: kind), privacy: .public) \(detail, privacy: .private)")
            throw OracleCoreError.tlsHandshakeFailed(kind: kind, serverMessage: detail)
        } catch let coreError as OracleCoreError {
            throw coreError
        } catch {
            let detail = String(describing: error)
            osLogger.error("Oracle connection failed: \(String(describing: type(of: error)), privacy: .public) \(detail, privacy: .private)")
            if let kind = OracleSSLClassifier.classifyTLSFailure(detail) {
                throw OracleCoreError.tlsHandshakeFailed(kind: kind, serverMessage: detail)
            }
            throw OracleCoreError.connectionFailed(detail)
        }
    }

    static func authenticationMode(for role: OracleConnectionOptions.Role) -> OracleNIO.AuthenticationMode {
        switch role {
        case .normal: return .default
        case .sysdba: return .sysDBA
        case .sysoper: return .sysOPER
        }
    }

    static func encryptionLevel(
        for level: OracleConnectionOptions.NetworkEncryption
    ) -> OracleNIO.NativeNetworkEncryptionLevel {
        switch level {
        case .rejected: return .rejected
        case .accepted: return .accepted
        case .requested: return .requested
        case .required: return .required
        }
    }

    private func connectError(from sqlError: OracleSQLError) -> OracleCoreError {
        let detail = Self.connectFailureDetail(sqlError)
        let phase = sqlError.handshakePhase
        osLogger.error(
            "Oracle connection failed at phase \(phase ?? "unknown", privacy: .public) (\(sqlError.code.description, privacy: .public))"
        )
        if let kind = OracleSSLClassifier.classifyTLSFailure(detail) {
            return .tlsHandshakeFailed(kind: kind, serverMessage: detail)
        }
        let failure = OracleConnectErrorClassifier.classify(sqlError.code.description)
        if case .loginHandshakeTimedOut = failure {
            return .loginHandshakeStalled(phase: phase)
        }
        if case .advancedNegotiationRequired = failure {
            return .nativeEncryptionRequired
        }
        if OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: failure,
            nativeNetworkEncryptionEnabled: options.networkEncryption != .rejected,
            timedOut: false
        ) {
            return .nativeEncryptionFailed(detail: detail)
        }
        switch failure {
        case .verifierUnsupported(let flag):
            return .authVerifierUnsupported(flag: flag)
        case .versionNotSupported:
            return .authVersionNotSupported
        case .connectionDropped:
            return .authConnectionDropped(phase: phase)
        case .advancedNegotiationFailed:
            return .nativeEncryptionFailed(detail: detail)
        case .advancedNegotiationRequired:
            return .nativeEncryptionRequired
        case .loginHandshakeTimedOut:
            return .loginHandshakeStalled(phase: phase)
        case .connectionFailed:
            return .connectionFailed(detail)
        }
    }

    private static func connectFailureDetail(_ error: OracleSQLError) -> String {
        if let refused = error.underlying as? OracleListenerRefusedError {
            return OracleListenerRefusal.detail(code: refused.code)
        }
        if let serverMessage = error.serverInfo?.message {
            return serverMessage
        }
        if let underlying = error.underlying {
            return String(describing: underlying)
        }
        return String(format: OracleCoreError.driverErrorFormat, error.code.description)
    }

    public func disconnect(reason: OracleDisconnectReason = .userRequested) {
        let connection = state.withLock { current -> OracleNIO.OracleConnection? in
            current.close.record(reason)
            guard current.isConnected else { return nil }
            current.isConnected = false
            let connection = current.nioConnection
            current.nioConnection = nil
            return connection
        }

        guard let connection else { return }

        Task {
            try? await connection.close()
            osLogger.notice("Closed the Oracle connection: \(reason.logDescription, privacy: .public)")
        }
    }

    /// OracleNIO has no out-of-band cancel, so closing the channel is the only
    /// way to abort an in-flight statement. The next query redials and restores
    /// the session schema, which is the same recovery a query timeout uses.
    public func cancelCurrentQuery() {
        disconnect(reason: .queryCancelled)
    }

    public func applyQueryTimeout(_ seconds: Int) {
        state.withLock { $0.queryTimeoutSeconds = max(0, seconds) }
    }

    public func noteSessionSchema(_ schema: String) {
        state.withLock { $0.sessionSchema = schema }
    }

    /// How long a statement may hold the channel before a probe that cannot get a turn treats it
    /// as wedged rather than as evidence the connection is alive. It is the app's own
    /// `max(queryTimeout, 300)` staleness rule, read from the timeout the app already told the
    /// driver about, so the two cannot drift. An unlimited query timeout is the user saying a
    /// statement may run for as long as it runs, and the floor still catches a socket that died
    /// without closing.
    private var wedgedStatementSeconds: Double {
        max(Double(state.withLock { $0.queryTimeoutSeconds }), 300)
    }

    /// Answers whether this connection still works, without ever taking the channel away from
    /// whoever is using it.
    ///
    /// A probe may close a channel only while it owns it. The old shape wrapped `executeQuery` in
    /// a ten second deadline, and `executeQuery` opens by waiting on the query gate, so the
    /// deadline covered the queue rather than the round trip: a probe that never got a turn fired
    /// `disconnect()` into a healthy statement, which OracleNIO reports to that statement as
    /// `clientClosedConnection` (#3053).
    ///
    /// A statement already in flight answers the question better than a probe could, so a busy
    /// channel reads as alive. Past ``wedgedStatementSeconds`` it reads as wedged instead, which
    /// is what keeps the app's own stale-query escape valve working.
    ///
    /// It asks OracleNIO directly rather than running `SELECT 1` through the app's statement path:
    /// there is no transaction role to admit, no autocommit flag to choose, and no silent redial,
    /// so a connection that has gone away reports that it has gone away instead of reporting the
    /// health of a replacement nobody asked for.
    public func ping() async throws {
        let turn = await queryGate.takeTurnIfFree()
        switch OraclePingDecision.of(turn, wedgedAfter: .seconds(wedgedStatementSeconds)) {
        case .reportAlive:
            return
        case .reportWedged:
            osLogger.error(
                "An Oracle statement has held the connection past the staleness limit; treating it as wedged"
            )
            disconnect(reason: .wedgedStatement)
            throw OracleCoreError.connectionClosed
        case .probe:
            break
        }

        /// Read after the turn is taken, so the handle pinged is the one the channel holds now
        /// rather than one a reconnect replaced while this was deciding.
        guard let connection = state.withLock({ $0.isConnected ? $0.nioConnection : nil }) else {
            await queryGate.release()
            throw OracleCoreError.notConnected
        }
        guard !connection.isClosed else {
            markConnectionDead(reason: .channelAlreadyClosed)
            await queryGate.release()
            throw OracleCoreError.connectionClosed
        }

        do {
            try await withOracleTimeout(
                seconds: Self.pingTimeoutSeconds,
                onTimeout: { [self] in disconnect(reason: .pingTimedOut) },
                operation: { try await connection.ping() }
            )
            await queryGate.release()
        } catch is OracleTimeoutError {
            await queryGate.release()
            throw OracleCoreError.connectionClosed
        } catch {
            let mapped = mapExecutionError(error)
            await queryGate.release()
            throw mapped
        }
    }

    // MARK: - Query Execution

    private func requireConnection() throws -> OracleNIO.OracleConnection {
        try state.withLock { current in
            guard let connection = current.nioConnection, current.isConnected else {
                throw OracleCoreError.notConnected
            }
            return connection
        }
    }

    /// Dropping the reference does not close the socket, and `disconnect()` refuses to act once the
    /// connection is marked dead, so a channel abandoned here would stay open on the server for the life
    /// of the process. Extracted in the same single `withLock` `disconnect()` uses, so two racing closers
    /// cannot both reach `close()`.
    private func markConnectionDead(reason: OracleDisconnectReason) {
        let connection = state.withLock { current -> OracleNIO.OracleConnection? in
            current.isConnected = false
            current.close.record(reason)
            let connection = current.nioConnection
            current.nioConnection = nil
            return connection
        }

        guard let connection else { return }

        Task {
            try? await connection.close()
            osLogger.notice(
                "Closed the Oracle connection after it was marked dead: \(reason.logDescription, privacy: .public)"
            )
        }
    }

    /// Serialized behind the query gate, so at most one reconnect runs at a time.
    /// Reconnecting restores the session schema, which ALTER SESSION state does
    /// not survive across connections.
    private func reconnectedConnection() async throws -> OracleNIO.OracleConnection {
        if let connection = state.withLock({ $0.isConnected ? $0.nioConnection : nil }) {
            return connection
        }
        /// A statement that was queued behind the gate when the app disconnected must find this
        /// connection finished. Without this it redials instead, and the socket it opens belongs to
        /// nobody: the plugin has already dropped this connection and the app has removed the
        /// session, so nothing will ever close it.
        guard state.withLock({ $0.hasEverConnected && $0.close.allowsReconnect }) else {
            throw OracleCoreError.notConnected
        }

        osLogger.notice("Reconnecting to Oracle after the previous connection was closed")
        try await connect()
        let connection = try requireConnection()
        if let schema = state.withLock({ $0.sessionSchema }) {
            _ = try await withQueryDeadline { [self] in
                try await collectRows(
                    OracleSchemaQueries.setCurrentSchema(schema),
                    options: Self.sessionSetupOptions,
                    on: connection
                )
            }
        }
        if state.withLock({ $0.capturesServerOutput }) {
            _ = try await withQueryDeadline { [self] in
                try await collectRows(
                    OracleServerOutput.enableStatement,
                    options: Self.sessionSetupOptions,
                    on: connection
                )
            }
        }
        return connection
    }

    // MARK: - Transactions

    /// Whether a transaction is open on this session, from ``beginTransaction()`` or from a statement that opens one,
    /// until a `COMMIT` or `ROLLBACK` ends it.
    public var holdsTransaction: Bool {
        state.withLock { $0.transaction.isOpen }
    }

    /// Holds every statement that follows in one transaction, until a `COMMIT` or `ROLLBACK` runs on the session.
    ///
    /// Oracle has no statement that opens a transaction the way `BEGIN` does elsewhere: the first write opens one. So
    /// this sends nothing, and the statements after it simply stop committing as they run.
    public func beginTransaction() {
        state.withLock { $0.transaction.open() }
    }

    /// The options a statement in `role` runs with, and the connection it runs on. Read under the query gate and after
    /// any reconnect, so the connection a transaction is bound to is the one the statement runs on.
    private func admit(_ role: OracleTransactionRole) throws -> (options: StatementOptions, session: Int) {
        try state.withLock { current in
            let autoCommit = try current.transaction.admit(role, on: current.sessionID)
            return (StatementOptions(autoCommit: autoCommit), current.sessionID)
        }
    }

    private func recordSuccess(of role: OracleTransactionRole, on session: Int) {
        state.withLock { $0.transaction.statementSucceeded(role, on: session) }
    }

    /// Called under the query gate, so the answer about the transaction comes from the connection the refused
    /// `COMMIT` or `ROLLBACK` ran on.
    private func recordFailure(of role: OracleTransactionRole) async {
        guard role == .endsTransaction, holdsTransaction else { return }
        let serverHoldsTransaction = await serverHoldsTransaction()
        state.withLock { $0.transaction.statementFailed(role, serverHoldsTransaction: serverHoldsTransaction) }
    }

    private func serverHoldsTransaction() async -> Bool? {
        guard let connection = state.withLock({ $0.isConnected ? $0.nioConnection : nil }) else { return nil }
        let answer = try? await withQueryDeadline { [self] in
            try await collectRows(
                OracleSessionTransaction.serverTransactionQuery,
                options: Self.sessionSetupOptions,
                on: connection
            )
        }
        guard let answer else { return nil }
        return answer.rows.first?.first.map { $0 != .null } ?? false
    }

    // MARK: - Server Output

    /// Turns `DBMS_OUTPUT` on for this session, and for every session a reconnect replaces it with, since the setting
    /// belongs to the session and a new one starts with it off.
    public func captureServerOutput() async throws {
        state.withLock { $0.capturesServerOutput = true }
        _ = try await executeQuery(OracleServerOutput.enableStatement)
    }

    /// Reads and consumes the lines the session has written since the last read, at most `maxLines` of them.
    ///
    /// One round trip: the block reads the lines with `GET_LINE`, splits them into pieces, and opens a cursor over them,
    /// which the caller rejoins. It reads `DBMS_OUTPUT` only through `EXECUTE IMMEDIATE` of a `CALL`, so a package named
    /// `SYS` in a schema the session has switched into cannot capture the drain, which the block form was measured to
    /// allow. The split has to happen in PL/SQL: a line can be 32767 bytes, and measured on Oracle 23ai with
    /// `MAX_STRING_SIZE=STANDARD` any SQL over a longer-than-4000-byte element fails with ORA-00910 on the cursor's
    /// first fetch, so one long line would turn the whole read into an error and lose every other line.
    ///
    /// A session that is closed has lost its buffer with it, so it reads as no output rather than paying for a
    /// reconnect: a query timeout or a dropped transport closes the connection, and the statement's error would
    /// otherwise wait on a whole login before it could be shown.
    public func drainServerOutput(maxLines: Int) async throws -> OracleServerOutput {
        guard state.withLock({ $0.capturesServerOutput }), maxLines > 0 else { return .empty }
        await queryGate.acquire()

        guard let connection = state.withLock({ $0.isConnected ? $0.nioConnection : nil }) else {
            await queryGate.release()
            return .empty
        }
        do {
            let output = try await withQueryDeadline { [self] in
                try await readServerOutput(on: connection, maxLines: maxLines)
            }
            await queryGate.release()
            return output
        } catch {
            let mapped = mapExecutionError(error)
            await queryGate.release()
            throw mapped
        }
    }

    private func readServerOutput(
        on connection: OracleNIO.OracleConnection,
        maxLines: Int
    ) async throws -> OracleServerOutput {
        let countRef = OracleRef(dataType: .number)
        let pieceCountRef = OracleRef(dataType: .number)
        let cursorRef = OracleRef(dataType: .cursor)
        var binds = OracleBindings()
        binds.append(countRef, bindName: OracleServerOutput.lineCountBindName, isReturning: false)
        binds.append(pieceCountRef, bindName: OracleServerOutput.pieceCountBindName, isReturning: false)
        binds.append(cursorRef, bindName: OracleServerOutput.piecesBindName, isReturning: false)
        let statement = OracleStatement(unsafeSQL: OracleServerOutput.drainBlock(maxLines: maxLines), binds: binds)
        try await connection.execute(statement, logger: nioLogger)
        let count: Int = try countRef.decode()
        let cursor = try cursorRef.decode(as: Cursor.self)
        var pieces: [String?] = []
        for try await row in try await cursor.execute(on: connection, logger: nioLogger) {
            pieces.append(try row.decode(String?.self))
        }
        return OracleServerOutput.read(pieces: pieces, reportedCount: count, cap: maxLines)
    }

    /// Races the operation against the configured query timeout. On timeout the
    /// connection is closed first, which fails the in-flight OracleNIO call even
    /// if it ignores task cancellation, so the race can always unwind.
    private func withQueryDeadline<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeoutSeconds = state.withLock { $0.queryTimeoutSeconds }
        guard timeoutSeconds > 0 else { return try await operation() }

        return try await withOracleTimeout(
            seconds: Double(timeoutSeconds),
            onTimeout: { [self] in disconnect(reason: .queryTimedOut) },
            operation: operation
        )
    }

    /// `OracleSQLError.description` never reaches the user. OracleNIO's own documentation says these
    /// errors "should not be forwareded to the end user, as they may leak sensitive information",
    /// and forwarding one is how a closed channel came out as
    /// `OracleSQLError(code: clientClosedConnection, ...)` in an alert (#3053). The server's own
    /// message is the one worth showing; without it the code's name says more than its struct dump,
    /// and the full description goes to the log instead.
    private func mapQueryError(_ sqlError: OracleSQLError) -> OracleCoreError {
        let code = sqlError.code.description
        guard OracleChannelFatalCode.isChannelFatal(
            code, serverErrorNumber: sqlError.serverInfo.map { Int($0.number) }
        ) else {
            guard let serverMessage = sqlError.serverInfo?.message else {
                osLogger.error("Oracle statement failed with \(code, privacy: .public): \(String(describing: sqlError), privacy: .private)")
                return .queryFailed(String(format: OracleCoreError.driverErrorFormat, code))
            }
            return .queryFailed(serverMessage)
        }

        switch OracleChannelFatalCode.closureKind(code) {
        case .clientClose:
            markConnectionDead(reason: .channelAlreadyClosed)
            osLogger.error("Oracle statement failed because this side had closed the channel: \(code, privacy: .public)")
            return .connectionClosed
        case .transportLoss:
            markConnectionDead(reason: .transportError)
            osLogger.error("Oracle connection lost during a statement: \(code, privacy: .public)")
            return .connectionClosed
        case .protocolFailure:
            markConnectionDead(reason: .fatalProtocolError)
            osLogger.error("Oracle connection reset after a fatal error: \(code, privacy: .public)")
            /// ORA-00028 and ORA-00600 end the session, and the server says why better than any
            /// wording here could. Everything else that reaches this point is the protocol failing.
            guard let serverMessage = sqlError.serverInfo?.message else { return .protocolError }
            return .queryFailed(serverMessage)
        }
    }

    /// A socket the system reclaimed while the app was suspended surfaces as a
    /// transport failure, never as an OracleSQLError, so it can never reach the
    /// channel-fatal classifier. Treating any unrecognized failure as fatal is
    /// what lets the next call redial instead of reusing a dead connection.
    private func mapExecutionError(_ error: Error) -> Error {
        switch error {
        case let timeout as OracleTimeoutError:
            osLogger.error("Oracle query timed out after \(Int(timeout.seconds), privacy: .public)s; the connection was closed to recover")
            return OracleCoreError.queryTimedOut
        case let sqlError as OracleSQLError:
            return mapQueryError(sqlError)
        case let coreError as OracleCoreError:
            return coreError
        case is CancellationError:
            return error
        default:
            markConnectionDead(reason: .transportError)
            let detail = String(describing: error)
            osLogger.error("Oracle connection reset after a transport error: \(String(describing: type(of: error)), privacy: .public) \(detail, privacy: .private)")
            return OracleCoreError.queryFailed(detail)
        }
    }

    public func executeQuery(_ query: String) async throws -> OracleRawResult {
        let role = OracleTransactionRole(of: query)
        await queryGate.acquire()

        do {
            let connection = try await reconnectedConnection()
            let admitted = try admit(role)
            let result = try await withQueryDeadline { [self] in
                try await collectRows(query, options: admitted.options, on: connection)
            }
            recordSuccess(of: role, on: admitted.session)
            await queryGate.release()
            return result
        } catch {
            /// Classified before the gate is released, because releasing it resumes a queued caller that
            /// can redial and install a new connection. Marking the failure dead after that would tear
            /// down the connection the next query is already running on.
            let mapped = mapExecutionError(error)
            await recordFailure(of: role)
            await queryGate.release()
            throw mapped
        }
    }

    /// Runs a statement that only configures the session, retrying it once across a channel this
    /// side closed.
    ///
    /// Replaying an arbitrary statement across a reconnect is never safe, because the new session
    /// holds none of the old one's state. A session-setup statement is the exception by
    /// construction: it is one of the statements ``reconnectedConnection()`` already replays for
    /// itself on every reconnect, so running it again is what the connection would have done
    /// anyway. The retry redials through that same path, and a transaction bound to the closed
    /// session still fails at ``OracleSessionTransaction/admit(_:on:)`` rather than carrying on in
    /// a session that holds none of its work.
    public func executeSessionSetup(_ query: String) async throws -> OracleRawResult {
        do {
            return try await executeQuery(query)
        } catch OracleCoreError.connectionClosed {
            guard state.withLock({ $0.close.allowsSessionSetupReplay }) else {
                throw OracleCoreError.connectionClosed
            }
            osLogger.notice("Retrying an Oracle session setup statement on a fresh connection")
            return try await executeQuery(query)
        }
    }

    private func collectRows(
        _ query: String,
        options: StatementOptions,
        on connection: OracleNIO.OracleConnection
    ) async throws -> OracleRawResult {
        let statement = OracleStatement(stringLiteral: query)
        let stream = try await connection.execute(statement, options: options, logger: nioLogger)

        let columnNames = stream.columns.map(\.name)
        var columnTypeNames: [String] = []
        var allRows: [[OracleRawCell]] = []
        var didReadTypes = false
        var truncated = false

        for try await row in stream {
            var rowValues: [OracleRawCell] = []
            for cell in row {
                if !didReadTypes {
                    columnTypeNames.append(Self.oracleTypeName(cell.dataType))
                }
                rowValues.append(decodeCell(cell))
            }
            didReadTypes = true
            allRows.append(rowValues)
            if allRows.count >= OracleRowLimits.emergencyMax {
                truncated = true
                break
            }
        }

        // A statement that returns no rows still wrote some, and the stream carries that count once
        // it has completed. Reporting the rows read instead answered 0 for every INSERT, UPDATE and
        // DELETE, so nothing downstream could tell a write that changed nothing from one that did
        // what it meant to. A truncated read never completed, so its count is not available.
        var affectedRows = allRows.count
        if allRows.isEmpty, !truncated {
            affectedRows = (try? await stream.affectedRows) ?? 0
        }

        return OracleRawResult(
            columns: Self.descriptors(names: columnNames, typeNames: didReadTypes ? columnTypeNames : []),
            rows: allRows,
            affectedRows: affectedRows,
            isTruncated: truncated
        )
    }

    private static func descriptors(names: [String], typeNames: [String]) -> [OracleColumnDescriptor] {
        names.enumerated().map { index, name in
            OracleColumnDescriptor(name: name, typeName: typeNames[safe: index] ?? "unknown")
        }
    }

    // MARK: - Streaming

    public func streamQuery(
        _ query: String,
        continuation: AsyncThrowingStream<OracleStreamElement, Error>.Continuation
    ) async throws {
        let role = OracleTransactionRole(of: query)
        await queryGate.acquire()

        do {
            let connection = try await reconnectedConnection()
            let admitted = try admit(role)
            try await withQueryDeadline { [self] in
                try await streamRows(query, options: admitted.options, on: connection, continuation: continuation)
            }
            recordSuccess(of: role, on: admitted.session)
            await queryGate.release()
            continuation.finish()
        } catch {
            let mapped = mapExecutionError(error)
            await recordFailure(of: role)
            await queryGate.release()
            throw mapped
        }
    }

    private func streamRows(
        _ query: String,
        options: StatementOptions,
        on connection: OracleNIO.OracleConnection,
        continuation: AsyncThrowingStream<OracleStreamElement, Error>.Continuation
    ) async throws {
        let statement = OracleStatement(stringLiteral: query)
        let stream = try await connection.execute(statement, options: options, logger: nioLogger)

        let columnNames = stream.columns.map(\.name)
        var columnTypeNames: [String] = []
        var headerSent = false

        for try await row in stream {
            try Task.checkCancellation()

            var rowValues: [OracleRawCell] = []
            for cell in row {
                if !headerSent {
                    columnTypeNames.append(Self.oracleTypeName(cell.dataType))
                }
                rowValues.append(decodeCell(cell))
            }

            if !headerSent {
                continuation.yield(.header(columns: Self.descriptors(names: columnNames, typeNames: columnTypeNames)))
                headerSent = true
            }

            continuation.yield(.rows([rowValues]))
        }

        if !headerSent {
            continuation.yield(.header(columns: Self.descriptors(names: columnNames, typeNames: [])))
        }
    }

    // MARK: - Cell Decoding

    private func decodeCell(_ cell: OracleCell) -> OracleRawCell {
        guard cell.bytes != nil else { return .null }

        if cell.dataType == .raw || cell.dataType == .longRAW || cell.dataType == .blob,
           let bytes = cell.bytes {
            return .bytes(Data(bytes.readableBytesView))
        }

        guard let text = decodeText(cell) else { return .null }
        return .string(text)
    }

    private func decodeText(_ cell: OracleCell) -> String? {
        do {
            switch cell.dataType {
            case .varchar, .nVarchar, .char, .nChar, .long, .longNVarchar,
                 .clob, .nCLOB, .json, .rowID:
                return try cell.decode(String.self)

            case .number, .binaryInteger:
                return Self.decodeNumber(cell)

            case .binaryFloat:
                return String(try cell.decode(Float.self))

            case .binaryDouble:
                return String(try cell.decode(Double.self))

            case .boolean:
                return try cell.decode(Bool.self) ? "true" : "false"

            case .date:
                return OracleCellFormatting.formatDate(try cell.decode(Date.self))

            case .timestamp:
                return OracleCellFormatting.formatTimestamp(try cell.decode(Date.self), style: .naive)

            case .timestampLTZ, .timestampTZ:
                return OracleCellFormatting.formatTimestamp(try cell.decode(Date.self), style: .local)

            case .intervalDS:
                let interval = try cell.decode(IntervalDS.self)
                return OracleCellFormatting.formatIntervalDS(
                    days: interval.days,
                    hours: interval.hours,
                    minutes: interval.minutes,
                    seconds: interval.seconds,
                    nanoseconds: interval.fractionalSeconds
                )

            case .intervalYM:
                let interval = try cell.decode(IntervalYM.self)
                return OracleCellFormatting.formatIntervalYM(
                    years: interval.years,
                    months: interval.months
                )

            case .bFile:
                return "<bfile>"

            case .cursor:
                return "<cursor>"

            case .vector:
                return "<vector>"

            default:
                return unsupportedPlaceholder(for: cell.dataType)
            }
        } catch {
            osLogger.error("Oracle decode failed for column '\(cell.columnName, privacy: .private(mask: .hash))': \(String(describing: type(of: error)), privacy: .public) \(String(describing: error), privacy: .private)")
            return "<decode error>"
        }
    }

    private func unsupportedPlaceholder(for type: OracleDataType) -> String {
        let name = Self.oracleTypeName(type)
        let warner = unsupportedWarner
        Task.detached {
            if await warner.warnIfNew(name) {
                osLogger.warning("Oracle column type '\(name, privacy: .public)' is not supported; rendering as placeholder")
            }
        }
        return OracleCellFormatting.unsupportedPlaceholder(typeName: name)
    }

    private static func decodeNumber(_ cell: OracleCell) -> String? {
        if let value = try? cell.decode(Int.self) {
            return String(value)
        }
        if let value = try? cell.decode(OracleNumber.self) {
            return value.description
        }
        if let value = try? cell.decode(Double.self) {
            return String(value)
        }
        return nil
    }

    static func oracleTypeName(_ dataType: OracleDataType) -> String {
        if dataType == .varchar { return "varchar2" }
        if dataType == .number { return "number" }
        if dataType == .binaryFloat { return "binary_float" }
        if dataType == .binaryDouble { return "binary_double" }
        if dataType == .date { return "date" }
        if dataType == .raw { return "raw" }
        if dataType == .longRAW { return "long raw" }
        if dataType == .char { return "char" }
        if dataType == .nChar { return "nchar" }
        if dataType == .nVarchar { return "nvarchar2" }
        if dataType == .nCLOB { return "nclob" }
        if dataType == .clob { return "clob" }
        if dataType == .blob { return "blob" }
        if dataType == .bFile { return "bfile" }
        if dataType == .timestamp { return "timestamp" }
        if dataType == .timestampTZ { return "timestamp with time zone" }
        if dataType == .timestampLTZ { return "timestamp with local time zone" }
        if dataType == .intervalDS { return "interval day to second" }
        if dataType == .intervalYM { return "interval year to month" }
        if dataType == .rowID { return "rowid" }
        if dataType == .boolean { return "boolean" }
        if dataType == .long { return "long" }
        if dataType == .json { return "json" }
        if dataType == .vector { return "vector" }
        if dataType == .binaryInteger { return "binary_integer" }
        return "unknown"
    }
}
