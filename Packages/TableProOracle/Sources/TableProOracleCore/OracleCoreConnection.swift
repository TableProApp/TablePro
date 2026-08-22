import Foundation
import Logging
import NIOCore
import NIOSSL
import OracleNIO
import OSLog

private let osLogger = Logger(subsystem: "com.TablePro", category: "OracleCoreConnection")

/// OracleNIO does not support concurrent queries on a single connection.
/// Sending a second statement while the first stream is active corrupts the
/// state machine. This actor serializes all executeQuery calls.
private actor QueryGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            busy = false
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

    private let options: OracleConnectionOptions
    private let queryGate = QueryGate()
    private let unsupportedWarner = UnsupportedTypeWarner()
    private let nioLogger = Logging.Logger(label: "com.TablePro.oracle-nio")

    private struct LockedState: Sendable {
        var isConnected = false
        var hasEverConnected = false
        var nioConnection: OracleNIO.OracleConnection?
        var queryTimeoutSeconds = 0
        var sessionSchema: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: LockedState())

    public var isConnected: Bool {
        state.withLock { $0.isConnected }
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
        let connectConfig = configuration
        let connectLogger = nioLogger

        let connectionId = Self.connectionCounter.withLock { counter -> Int in
            counter += 1
            return counter
        }

        do {
            let connection = try await withOracleTimeout(seconds: options.loginTimeoutSeconds) {
                try await OracleNIO.OracleConnection.connect(
                    configuration: connectConfig,
                    id: connectionId,
                    logger: connectLogger
                )
            }

            state.withLock { current in
                current.nioConnection = connection
                current.isConnected = true
                current.hasEverConnected = true
            }

            osLogger.debug("Connected to Oracle \(self.options.host, privacy: .public):\(self.options.port, privacy: .public)")
        } catch is OracleTimeoutError {
            osLogger.error("Oracle login handshake timed out after \(self.options.loginTimeoutSeconds, privacy: .public)s")
            throw OracleCoreError.loginTimedOut
        } catch let sqlError as OracleSQLError {
            throw connectError(from: sqlError)
        } catch let nioSslError as NIOSSLError {
            let detail = String(describing: nioSslError)
            osLogger.error("Oracle TLS error: \(detail, privacy: .public)")
            throw OracleCoreError.tlsHandshakeFailed(
                kind: OracleSSLClassifier.classifyTLSFailure(detail) ?? .unknown,
                serverMessage: detail
            )
        } catch let coreError as OracleCoreError {
            throw coreError
        } catch {
            let detail = String(describing: error)
            osLogger.error("Oracle connection failed: \(detail, privacy: .public)")
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
        // Native network encryption is always offered at ACCEPTED, so a non-timeout
        // advanced-negotiation failure is the one definitive encryption signal.
        if OracleConnectErrorClassifier.isLikelyNativeEncryptionFailure(
            failure: failure,
            nativeNetworkEncryptionEnabled: true,
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
        return error.description
    }

    public func disconnect() {
        let connection = state.withLock { current -> OracleNIO.OracleConnection? in
            guard current.isConnected else { return nil }
            current.isConnected = false
            let connection = current.nioConnection
            current.nioConnection = nil
            return connection
        }

        guard let connection else { return }

        Task {
            try? await connection.close()
            osLogger.debug("Disconnected from Oracle")
        }
    }

    /// OracleNIO has no out-of-band cancel, so closing the channel is the only
    /// way to abort an in-flight statement. The next query redials and restores
    /// the session schema, which is the same recovery a query timeout uses.
    public func cancelCurrentQuery() {
        disconnect()
    }

    public func applyQueryTimeout(_ seconds: Int) {
        state.withLock { $0.queryTimeoutSeconds = max(0, seconds) }
    }

    public func noteSessionSchema(_ schema: String) {
        state.withLock { $0.sessionSchema = schema }
    }

    /// A health check must never inherit the user's query timeout, which is
    /// unlimited by default. Without its own deadline a dead socket can leave
    /// the caller waiting forever instead of triggering a reconnect.
    public func ping() async throws {
        _ = try await withOracleTimeout(
            seconds: Self.pingTimeoutSeconds,
            onTimeout: { [self] in disconnect() },
            operation: { [self] in try await executeQuery(OracleSchemaQueries.ping) }
        )
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
    private func markConnectionDead() {
        let connection = state.withLock { current -> OracleNIO.OracleConnection? in
            current.isConnected = false
            let connection = current.nioConnection
            current.nioConnection = nil
            return connection
        }

        guard let connection else { return }

        Task {
            try? await connection.close()
            osLogger.debug("Closed the Oracle connection after it was marked dead")
        }
    }

    /// Serialized behind the query gate, so at most one reconnect runs at a time.
    /// Reconnecting restores the session schema, which ALTER SESSION state does
    /// not survive across connections.
    private func reconnectedConnection() async throws -> OracleNIO.OracleConnection {
        if let connection = state.withLock({ $0.isConnected ? $0.nioConnection : nil }) {
            return connection
        }
        guard state.withLock({ $0.hasEverConnected }) else {
            throw OracleCoreError.notConnected
        }

        osLogger.notice("Reconnecting to Oracle after the previous connection was closed")
        try await connect()
        let connection = try requireConnection()
        if let schema = state.withLock({ $0.sessionSchema }) {
            _ = try await withQueryDeadline { [self] in
                try await collectRows(OracleSchemaQueries.setCurrentSchema(schema), on: connection)
            }
        }
        return connection
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
            onTimeout: { [self] in disconnect() },
            operation: operation
        )
    }

    private func mapQueryError(_ sqlError: OracleSQLError) -> OracleCoreError {
        guard OracleChannelFatalCode.isChannelFatal(sqlError.code.description) else {
            return .queryFailed(sqlError.serverInfo?.message ?? sqlError.description)
        }
        markConnectionDead()
        osLogger.error("Oracle connection reset after fatal protocol error: \(sqlError.code.description, privacy: .public)")
        return .protocolError
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
            markConnectionDead()
            let detail = String(describing: error)
            osLogger.error("Oracle connection reset after a transport error: \(detail, privacy: .public)")
            return OracleCoreError.queryFailed(detail)
        }
    }

    public func executeQuery(_ query: String) async throws -> OracleRawResult {
        await queryGate.acquire()

        do {
            let connection = try await reconnectedConnection()
            let result = try await withQueryDeadline { [self] in
                try await collectRows(query, on: connection)
            }
            await queryGate.release()
            return result
        } catch {
            /// Classified before the gate is released, because releasing it resumes a queued caller that
            /// can redial and install a new connection. Marking the failure dead after that would tear
            /// down the connection the next query is already running on.
            let mapped = mapExecutionError(error)
            await queryGate.release()
            throw mapped
        }
    }

    private func collectRows(
        _ query: String,
        on connection: OracleNIO.OracleConnection
    ) async throws -> OracleRawResult {
        let statement = OracleStatement(stringLiteral: query)
        let stream = try await connection.execute(statement, logger: nioLogger)

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

        return OracleRawResult(
            columns: Self.descriptors(names: columnNames, typeNames: didReadTypes ? columnTypeNames : []),
            rows: allRows,
            affectedRows: allRows.count,
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
        await queryGate.acquire()

        do {
            let connection = try await reconnectedConnection()
            try await withQueryDeadline { [self] in
                try await streamRows(query, on: connection, continuation: continuation)
            }
            await queryGate.release()
            continuation.finish()
        } catch {
            let mapped = mapExecutionError(error)
            await queryGate.release()
            throw mapped
        }
    }

    private func streamRows(
        _ query: String,
        on connection: OracleNIO.OracleConnection,
        continuation: AsyncThrowingStream<OracleStreamElement, Error>.Continuation
    ) async throws {
        let statement = OracleStatement(stringLiteral: query)
        let stream = try await connection.execute(statement, logger: nioLogger)

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
                return OracleCellFormatting.formatTimestamp(try cell.decode(Date.self), style: .utc)

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
            osLogger.error("Oracle decode failed for column '\(cell.columnName, privacy: .public)': \(String(describing: error), privacy: .public)")
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
